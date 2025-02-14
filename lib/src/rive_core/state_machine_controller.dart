import 'dart:collection';

import 'package:rive/src/core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:rive/src/rive_core/animation/animation_state_instance.dart';
import 'package:rive/src/rive_core/animation/any_state.dart';
import 'package:rive/src/rive_core/animation/layer_state.dart';
import 'package:rive/src/rive_core/animation/linear_animation.dart';
import 'package:rive/src/rive_core/animation/state_instance.dart';
import 'package:rive/src/rive_core/animation/state_machine.dart';
import 'package:rive/src/rive_core/animation/state_machine_layer.dart';
import 'package:rive/src/rive_core/animation/state_transition.dart';
import 'package:rive/src/rive_core/rive_animation_controller.dart';

class LayerController {
  final StateMachineLayer layer;
  final StateInstance anyStateInstance;

  StateInstance? _currentState;
  StateInstance? _stateFrom;
  bool _holdAnimationFrom = false;
  StateTransition? _transition;
  double _mix = 1.0;

  LayerController(this.layer)
      : assert(layer.anyState != null),
        anyStateInstance = layer.anyState!.makeInstance() {
    _changeState(layer.entryState);
  }

  bool _changeState(LayerState? state, {StateTransition? transition}) {
    assert(state is! AnyState,
        'We don\'t allow making the AnyState an active state.');
    if (state == _currentState?.state) {
      return false;
    }

    _currentState = state?.makeInstance();
    return true;
  }

  void dispose() {
    _changeState(null);
  }

  bool get isTransitioning =>
      _transition != null &&
      _stateFrom != null &&
      _transition!.duration != 0 &&
      _mix != 1;

  void _updateMix(double elapsedSeconds) {
    if (_transition != null &&
        _stateFrom != null &&
        _transition!.duration != 0) {
      _mix = (_mix + elapsedSeconds / _transition!.mixTime(_stateFrom!.state))
          .clamp(0, 1)
          .toDouble();
    } else {
      _mix = 1;
    }
  }

  void _apply(CoreContext core) {
    if (_holdAnimation != null) {
      _holdAnimation!.apply(_holdTime, coreContext: core, mix: _holdMix);
      _holdAnimation = null;
    }

    if (_stateFrom != null && _mix < 1) {
      _stateFrom!.apply(core, 1 - _mix);
    }
    if (_currentState != null) {
      _currentState!.apply(core, _mix);
    }
  }

  bool apply(StateMachineController machineController, CoreContext core,
      double elapsedSeconds, HashMap<int, dynamic> inputValues) {
    if (_currentState != null) {
      _currentState!.advance(elapsedSeconds, inputValues);
    }

    _updateMix(elapsedSeconds);

    if (_stateFrom != null && _mix < 1) {
      // This didn't advance during our updateState, but it should now that we
      // realize we need to mix it in.
      if (!_holdAnimationFrom) {
        _stateFrom!.advance(elapsedSeconds, inputValues);
      }
    }

    for (int i = 0; updateState(inputValues, i != 0); i++) {
      _apply(core);

      if (i == 100) {
        // Escape hatch, let the user know their logic is causing some kind of
        // recursive condition.
        print('StateMachineController.apply exceeded max iterations.');

        return false;
      }
    }

    _apply(core);

    return _mix != 1 || _waitingForExit || (_currentState?.keepGoing ?? false);
  }

  bool _waitingForExit = false;
  LinearAnimation? _holdAnimation;
  double _holdTime = 0;
  double _holdMix = 0;

  bool updateState(HashMap<int, dynamic> inputValues, bool ignoreTriggers) {
    if (isTransitioning) {
      return false;
    }
    _waitingForExit = false;
    if (tryChangeState(anyStateInstance, inputValues, ignoreTriggers)) {
      return true;
    }

    return tryChangeState(_currentState, inputValues, ignoreTriggers);
  }

  bool tryChangeState(StateInstance? stateFrom,
      HashMap<int, dynamic> inputValues, bool ignoreTriggers) {
    if (stateFrom == null) {
      return false;
    }

    for (final transition in stateFrom.state.transitions) {
      var allowed = transition.allowed(stateFrom, inputValues, ignoreTriggers);
      if (allowed == AllowTransition.yes &&
          _changeState(transition.stateTo, transition: transition)) {
        // Take transition
        _transition = transition;
        _stateFrom = stateFrom;

        // If we had an exit time and wanted to pause on exit, make sure to hold
        // the exit time. Delegate this to the transition by telling it that it
        // was completed.
        if (transition.applyExitCondition(stateFrom)) {
          // Make sure we apply this state.
          var inst = (stateFrom as AnimationStateInstance).animationInstance;
          _holdAnimation = inst.animation;
          _holdTime = inst.time;
          _holdMix = _mix;
        }

        // Keep mixing last animation that was mixed in.
        if (_mix != 0) {
          _holdAnimationFrom = transition.pauseOnExit;
        }
        if (stateFrom is AnimationStateInstance) {
          var spilledTime = stateFrom.animationInstance.spilledTime;
          _currentState?.advance(spilledTime, inputValues);
        }

        _mix = 0;
        _updateMix(0);
        // Make sure to reset _waitingForExit to false if we succeed at taking a
        // transition.
        _waitingForExit = false;
        return true;
      } else if (allowed == AllowTransition.waitingForExit) {
        _waitingForExit = true;
      }
    }
    return false;
  }
}

class StateMachineController extends RiveAnimationController<CoreContext> {
  final StateMachine stateMachine;
  final inputValues = HashMap<int, dynamic>();
  StateMachineController(this.stateMachine);
  final layerControllers = <LayerController>[];

  void _clearLayerControllers() {
    for (final layer in layerControllers) {
      layer.dispose();
    }
    layerControllers.clear();
  }

  @override
  bool init(CoreContext core) {
    _clearLayerControllers();

    for (final layer in stateMachine.layers) {
      layerControllers.add(LayerController(layer));
    }

    // Make sure triggers are all reset.
    advanceInputs();

    return super.init(core);
  }

  @override
  void dispose() {
    _clearLayerControllers();
    super.dispose();
  }

  @protected
  void advanceInputs() {}

  @override
  void apply(CoreContext core, double elapsedSeconds) {
    bool keepGoing = false;
    for (final layerController in layerControllers) {
      if (layerController.apply(this, core, elapsedSeconds, inputValues)) {
        keepGoing = true;
      }
    }
    advanceInputs();
    isActive = keepGoing;
  }
}
