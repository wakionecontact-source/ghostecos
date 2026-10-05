import 'package:flutter_test/flutter_test.dart';

import 'package:ghost/models/call_media_route.dart';
import 'package:ghost/services/call_audio_constraints.dart';
import 'package:ghost/services/call_collision_policy.dart';

void main() {
  test('crossed calls resolve to one deterministic outgoing offer', () {
    final alice = resolveCallCollision(
      localUsername: 'alice',
      remoteUsername: 'bob',
      localCallId: 'alice-call',
      incomingCallId: 'bob-call',
    );
    final bob = resolveCallCollision(
      localUsername: 'bob',
      remoteUsername: 'alice',
      localCallId: 'bob-call',
      incomingCallId: 'alice-call',
    );

    expect(alice, CallCollisionDecision.keepOutgoing);
    expect(bob, CallCollisionDecision.acceptIncoming);
  });

  test('call audio constraints enable echo and noise processing', () {
    final constraints = callAudioConstraints();

    expect(constraints['echoCancellation'], isTrue);
    expect(constraints['noiseSuppression'], isTrue);
    expect(constraints['autoGainControl'], isTrue);
  });

  test('media route parser distinguishes direct and TURN relay paths', () {
    Map<String, dynamic> report(
      String id,
      String type,
      Map<String, dynamic> values,
    ) => {'id': id, 'type': type, 'values': values};

    expect(
      resolveCallMediaRouteFromStats([
        report('transport', 'transport', {'selectedCandidatePairId': 'pair'}),
        report('pair', 'candidate-pair', {
          'localCandidateId': 'local',
          'remoteCandidateId': 'remote',
          'state': 'succeeded',
          'nominated': true,
        }),
        report('local', 'local-candidate', {'candidateType': 'host'}),
        report('remote', 'remote-candidate', {'candidateType': 'srflx'}),
      ]),
      CallMediaRoute.direct,
    );

    expect(
      resolveCallMediaRouteFromStats([
        report('transport', 'transport', {'selectedCandidatePairId': 'pair'}),
        report('pair', 'candidate-pair', {
          'localCandidateId': 'local',
          'remoteCandidateId': 'remote',
          'state': 'succeeded',
          'nominated': true,
        }),
        report('local', 'local-candidate', {'candidateType': 'relay'}),
        report('remote', 'remote-candidate', {'candidateType': 'srflx'}),
      ]),
      CallMediaRoute.turnRelay,
    );
  });
}
