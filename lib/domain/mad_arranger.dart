import 'dart:math' as math;

import 'arrangement.dart';
import 'melody_template.dart';
import 'midi_score_data.dart';

/// A MAD made of the clips themselves: the melody is sung by the most tuneful
/// clip one syllable at a time, a low clip plays bass, sharp attacks become a
/// drum kit, and every clip still introduces itself in its own voice.
///
/// Structure (30 s, 16 bars at 128 BPM; 15 s is a compressed 8-bar version):
///   bars 1-2   introductions, the first one stuttered in
///   bars 3-4   beat + bass, tail echoes as fills
///   bars 5-12  the melody, two tuneful clips trading every two bars; clips
///              with no part of their own play whole, quietly, behind it
///   bars 13-14 break: drums drop, the longest phrase plays raw up front
///   bars 15-16 climax: the hook again, full kit, everyone stutters at the end
///
/// Each event says where in which clip it reads, so the renderer shows exactly
/// the moment being heard. Effects (rolls, risers, reverses, scratches, tape
/// stops, sweeps, ...) are drawn per slot from the seed, never all at once.
Arrangement arrangeMad({
  required List<AnalyzedClip> clips,
  required ArrangementStyle style,
  required int seed,
  required MelodyTemplate melodyTemplate,
  required int seconds,
}) {
  if (seconds != 15 && seconds != 30) {
    throw const MediaContractException('Choose a 15 or 30 second MAD.');
  }
  if (clips.isEmpty) {
    throw const ArrangementRejected(
      reason: ArrangementRejectionReason.noSources,
      assetIds: <String>[],
    );
  }
  if (clips.length > 6 ||
      clips.map((c) => c.assetId).toSet().length != clips.length) {
    throw const MediaContractException(
      'Arrangement requires 1 to 6 unique sources.',
    );
  }
  final audible = clips.where((c) => c.isUsable).toList();
  if (audible.isEmpty) {
    throw ArrangementRejected(
      reason: ArrangementRejectionReason.allSilent,
      assetIds: clips.map((c) => c.assetId).toList(),
    );
  }
  final builder = _MadBuilder(
    clips: clips,
    audible: audible,
    seed: seed,
    melodic: melodyTemplate != MelodyTemplate.none,
    total: seconds * _sampleRate,
  );
  if (seconds == 30) {
    builder.buildLong();
  } else {
    builder.buildShort();
  }
  return builder.finish(style: style, melodyTemplate: melodyTemplate);
}

const _sampleRate = 48000;
const _beat = Arrangement.beatSamples;
const _bar = Arrangement.barSamples;
const _sixteenth = _beat ~/ 4;

/// partIndex per role: audio and video share it, and one clip reused in
/// several roles reads as several different moments.
const _parts = {
  'phrase': 0,
  'chop': 1,
  'melody': 2,
  'bass': 3,
  'kick': 4,
  'snare': 5,
  'hat': 6,
  'fx': 7,
  'echo': 8,
  'stab': 9,
  'backing': 10,
};

class _Span {
  const _Span(this.start, this.length, [this.midi]);
  final int start;
  final int length;
  final double? midi;
  int get end => start + length;
}

/// What the arranger needs to know about one clip, with fallbacks for
/// analyses stored before the voice fields existed.
class _Voice {
  _Voice(this.clip) {
    final regions = clip.audibleRegions.isEmpty
        ? [
            AudibleRegion(
              startSample: clip.sourceStartSample,
              durationSamples: clip.durationSamples,
            ),
          ]
        : clip.audibleRegions.toList();
    byLength =
        regions
            .map(
              (r) => _Span(r.startSample, r.durationSamples, r.fundamentalMidiNote),
            )
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    final syllableSource = clip.syllables.isNotEmpty ? clip.syllables : regions;
    syllables =
        syllableSource
            .map(
              (r) => _Span(r.startSample, r.durationSamples, r.fundamentalMidiNote),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final runSource = clip.voicedRuns.isNotEmpty
        ? clip.voicedRuns
        : regions.where((r) => r.fundamentalMidiNote != null).toList();
    voicedRuns =
        runSource.map((r) => _Span(r.startSample, r.durationSamples)).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
  }

  final AnalyzedClip clip;
  late final List<_Span> byLength;
  late final List<_Span> syllables;
  late final List<_Span> voicedRuns;

  String get id => clip.assetId;
  int get start => clip.sourceStartSample;
  int get end => clip.sourceStartSample + clip.durationSamples;
  _Span get longest => byLength.first;
  double get voicedSeconds =>
      voicedRuns.fold<int>(0, (sum, r) => sum + r.length) / _sampleRate;
  double get medianMidi =>
      clip.registerMidiNote ?? clip.fundamentalMidiNote ?? 60;
  double get spread =>
      clip.pitchSpread ??
      (clip.fundamentalMidiNote != null
          ? 1
          : voicedRuns.isEmpty
          ? 99
          : 12);
  /// A high, pure whistle is retuned by speed: grains would add a low buzz
  /// when it is shifted down. Anything lower keeps its own voice through the
  /// grains, even when it measures as nearly pure (a distant rooster, a call).
  bool get pure => (clip.purity ?? 0) > .6 && medianMidi >= 88;

  /// The clearest sustained stretch: the body every sung note is read from.
  _Span get body => voicedRuns.isEmpty
      ? longest
      : voicedRuns.reduce((a, b) => b.length > a.length ? b : a);

  /// Everything the clip says, first sound to last.
  _Span get whole {
    final first = byLength.map((r) => r.start).reduce(math.min);
    final last = byLength.map((r) => r.end).reduce(math.max);
    return _Span(first, last - first);
  }

  /// Sharp attacks for the drum kit, earliest first.
  List<int> get attacks => clip.onsetSamples.isNotEmpty
      ? clip.onsetSamples.take(2).toList()
      : [syllables.first.start];
}

class _MadBuilder {
  _MadBuilder({
    required this.clips,
    required List<AnalyzedClip> audible,
    required this.seed,
    required this.melodic,
    required this.total,
  }) : random = math.Random(seed),
       voices = [for (final clip in clips) _Voice(clip)] {
    final loud = voices
        .where((v) => audible.contains(v.clip) && v.clip.peak >= .03)
        .toList();
    usable = loud.isNotEmpty
        ? loud
        : voices.where((v) => audible.contains(v.clip)).toList();
    _chooseRoles();
  }

  final List<AnalyzedClip> clips;
  final int seed;
  final List<_Voice> voices;
  final bool melodic;
  final int total;
  final math.Random random;
  late final List<_Voice> usable;
  late final List<_Voice> singers;
  late final _Voice lead;
  late final List<_Voice> others;
  late final _Voice bass;
  late final bool sampledBass;
  late final Map<String, (_Voice, int)> kit;
  late final List<(double, double, double)> melody;
  late final List<(double, double, double)> bassLine;
  final events = <SoundEvent>[];
  final masterEffects = <MasterEffect>[];
  final sections = <SongSection>[];

  // -- roles ------------------------------------------------------------------

  void _chooseRoles() {
    // Singers hold a steady pitch; bells and noisy cries make poor singers. A
    // second singer trades phrases only if it is nearly as tuneful.
    final candidates = usable.where((v) => v.voicedSeconds > .5).toList()
      ..sort((a, b) => a.spread.compareTo(b.spread));
    final chosen = <_Voice>[];
    if (candidates.isNotEmpty) {
      chosen.add(candidates.first);
      if (candidates.length > 1 &&
          candidates[1].spread <
              math.min(14.0, math.max(4.0, 1.5 * candidates.first.spread))) {
        chosen.add(candidates[1]);
      }
    } else {
      chosen.add(
        usable.reduce((a, b) => b.voicedSeconds > a.voicedSeconds ? b : a),
      );
    }
    singers = chosen;
    lead = singers.first;
    others = usable.where((v) => v != lead).toList();
    final pool = usable.where((v) => !singers.contains(v)).toList();
    final bassPool = pool.isNotEmpty
        ? pool
        : others.isNotEmpty
        ? others
        : [lead];
    final steady = bassPool.where((v) => v.voicedSeconds > .3).toList();
    bass = steady.isNotEmpty
        ? steady.reduce((a, b) => b.medianMidi < a.medianMidi ? b : a)
        : bassPool.reduce(
            (a, b) => _audibleLength(b) > _audibleLength(a) ? b : a,
          );
    sampledBass = bass.voicedSeconds <= .3;

    // The drum kit comes from the loudest real attacks, one clip per drum.
    final attacks = <(double, _Voice, int)>[
      for (final v in usable)
        for (final (i, onset) in v.attacks.indexed) (v.clip.peak / (1 + i), v, onset),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    final taken = <String>{};
    final drums = <String, (_Voice, int)>{};
    for (final drum in ['kick', 'snare', 'hat']) {
      final choice = attacks.firstWhere(
        (a) => !taken.contains(a.$2.id),
        orElse: () => attacks.first,
      );
      drums[drum] = (choice.$2, choice.$3);
      taken.add(choice.$2.id);
    }
    kit = drums;

    // The whole song moves to the lead voice's own register (a key change).
    final score = _score();
    melody = score.$1;
    final centre = _median(melody.map((n) => n.$3).toList());
    final shift = (lead.medianMidi - centre).round();
    final bassMid = sampledBass ? 45.0 : bass.medianMidi;
    bassLine = [
      for (final (b, l, m) in score.$2) (b, l, _into(m + shift, bassMid - 18, bassMid + 6)),
    ];
    _shift = shift.toDouble();
  }

  double _shift = 0;

  static int _audibleLength(_Voice v) =>
      v.byLength.fold<int>(0, (sum, r) => sum + r.length);

  static double _median(List<double> values) {
    if (values.isEmpty) return 60;
    final sorted = values.toList()..sort();
    return sorted[sorted.length ~/ 2];
  }

  static double _into(double midi, double low, double high) {
    var m = midi;
    while (m > high) {
      m -= 12;
    }
    while (m < low) {
      m += 12;
    }
    return m;
  }

  /// Beats, lengths in beats and MIDI notes of the bundled three-part score.
  static (List<(double, double, double)>, List<(double, double, double)>) _score() {
    List<(double, double, double)> lane(int index) => [
      for (final note in midiScoreNotes[index])
        (note[0] / 480, note[1] / 480, note[2].toDouble()),
    ];
    return (lane(0), lane(1));
  }

  /// Each singer takes the tune in the octave that keeps its highest and
  /// lowest notes closest to its own voice; the key never changes.
  List<(double, double, double)> _sungBy(_Voice singer) {
    final line = [for (final (b, l, m) in melody) (b, l, m + _shift)];
    if (line.isEmpty) return line;
    final top = line.map((n) => n.$3).reduce(math.max);
    final bottom = line.map((n) => n.$3).reduce(math.min);
    final med = singer.medianMidi;
    var best = 0;
    var bestCost = double.infinity;
    for (var k = -3; k <= 3; k++) {
      final o = 12 * k;
      final cost =
          math.max((top + o - med).abs(), (bottom + o - med).abs()) * 100 +
          o.abs();
      if (cost < bestCost) {
        bestCost = cost;
        best = o;
      }
    }
    return [for (final (b, l, m) in line) (b, l, m + best)];
  }

  // -- events -----------------------------------------------------------------

  /// Adds one event reading the clip inside its selected range. Returns the
  /// number of source samples it reads.
  int add(
    _Voice voice,
    int start,
    int duration,
    int source, {
    required String role,
    required double gain,
    int? span,
    double? note,
    double? rate,
    double? glide,
    double? scratch,
    int? scratchPeriod,
    bool reverse = false,
    int? gate,
    int? fadeIn,
    int? fadeOut,
  }) {
    if (start < 0 || start >= total) return 0;
    final clipLength = voice.end - voice.start;
    var length = math.min(duration, total - start);
    if (length < 48 || clipLength < 48) return 0;
    int read;
    if (glide != null) {
      read = _glideSpan(length, rate ?? 1, glide);
    } else if (rate != null) {
      read = (length * rate).ceil() + 2;
    } else if (scratch != null) {
      read = (scratch * _sampleRate).ceil() + 2;
    } else {
      read = span ?? length;
    }
    if (read > clipLength) {
      if (rate != null || glide != null) {
        // Too little sound for this speed: shorten the event instead.
        length = (length * (clipLength - 2) / read).floor();
        if (length < 48) return 0;
        read = clipLength;
      } else {
        read = clipLength;
      }
    }
    read = math.max(1, read);
    final from = math.min(math.max(source, voice.start), voice.end - read);
    final inFade = math.min(fadeIn ?? 96, length ~/ 4);
    final outFade = math.min(fadeOut ?? 600, length ~/ 4);
    events.add(
      SoundEvent(
        assetId: voice.id,
        sourceStartSample: from,
        sourceDurationSamples: read,
        destinationStartSample: start,
        durationSamples: length,
        gain: gain.clamp(0.0, 1.0).toDouble(),
        fades: EventFades(fadeInSamples: inFade, fadeOutSamples: outFade),
        partIndex: _parts[role] ?? 0,
        targetMidiNote: note?.clamp(24.0, 100.0).toDouble(),
        reverse: reverse,
        treatment: switch (role) {
          'phrase' || 'echo' || 'backing' => SoundTreatment.phrase,
          _ when note != null => SoundTreatment.tuned,
          _ => SoundTreatment.rhythm,
        },
        role: role,
        rate: rate == null ? null : _round(rate.clamp(.25, 4.0).toDouble()),
        glide: glide,
        scratch: scratch,
        scratchPeriod: scratchPeriod,
        gate: gate,
      ),
    );
    return read;
  }

  static double _round(double value) => (value * 10000).roundToDouble() / 10000;

  static int _glideSpan(int length, double rate, double glide) {
    var sum = 0.0;
    const steps = 64;
    for (var i = 0; i < steps; i++) {
      final t = (i + .5) / steps;
      sum += rate * math.pow(2, glide * t / 12) * length / steps;
    }
    return sum.ceil() + 2;
  }

  // -- building blocks --------------------------------------------------------

  int phrase(_Voice v, int start, _Span region, {double gain = 1, double limit = 1.4}) {
    final duration = math.min(region.length, (limit * _sampleRate).round());
    add(v, start, duration, region.start, role: 'phrase', gain: gain);
    return duration;
  }

  /// あっ、あっ、あっ — the first syllable on 16ths before the phrase.
  int stutterHead(_Voice v, int start, _Span region, {int times = 3, int step = _sixteenth, double gain = .9}) {
    final chop = math.min((.11 * _sampleRate).round(), region.length);
    for (var k = 0; k < times; k++) {
      add(v, start + k * step, chop, region.start, role: 'chop', gain: gain);
    }
    return times * step;
  }

  /// …とう、とう、とう — the last syllable repeated and fading.
  void tailEcho(_Voice v, int start, _Span region, {int times = 3, int step = _beat ~/ 2, double gain = .7}) {
    final chop = math.min((.18 * _sampleRate).round(), region.length);
    for (var k = 0; k < times; k++) {
      add(v, start + k * step, chop, region.end - chop, role: 'chop', gain: gain * math.pow(.8, k).toDouble());
    }
  }

  /// One note = the raw attack of the next syllable + a sung body read
  /// forward from the clip's clearest stretch, stopping at 85% of the note.
  /// Pure tones (whistles) are retuned by speed instead of by grains.
  (int, int?) syllableLine(_Voice v, (int, int?) cursor, List<(double, double, double)> notes, int barOffset, double gain) {
    var (k, pos) = cursor;
    final body = v.body;
    var at = pos ?? body.start;
    final attack = (.04 * _sampleRate).round();
    for (final (b, length, midi) in notes) {
      final start = ((b + barOffset * 4) * _beat).round();
      final duration = (length * _beat * .85).round();
      final syllable = v.syllables[k % v.syllables.length];
      final hit = math.min(attack, math.min(syllable.length, duration ~/ 3));
      add(v, start, hit, syllable.start, role: 'melody', gain: gain);
      final rest = duration - hit;
      if (rest > (.03 * _sampleRate).round()) {
        var speed = 1.0;
        if (v.pure) {
          final here = v.medianMidi;
          speed = math.pow(2, (midi - here) / 12).toDouble().clamp(.5, 2.0).toDouble();
        }
        var need = (rest * speed).round();
        if (need > body.length) {
          // A short run: a pure tone is read slower, a voice loops its run.
          if (v.pure) speed *= body.length / need;
          need = body.length;
          at = body.start;
        } else if (at + need > body.end) {
          at = body.start;
        }
        if (v.pure) {
          add(v, start + hit, rest, at, role: 'melody', gain: gain, rate: math.max(.25, speed));
        } else {
          add(v, start + hit, rest, at, role: 'melody', gain: gain, note: midi, span: need);
        }
        at += need;
      }
      k++;
    }
    return (k % v.syllables.length, at);
  }

  /// Bass sung continuously by a voiced clip (the words keep advancing), or
  /// played sampler-style by a clip with no steady pitch.
  (int, int?) bassPart((int, int?) cursor, List<(double, double, double)> notes, int barOffset, double gain) {
    var (ri, pos) = cursor;
    final runs = bass.voicedRuns.isNotEmpty && !sampledBass
        ? bass.voicedRuns
        : (bass.byLength.toList()..sort((a, b) => a.start.compareTo(b.start)));
    var at = pos ?? runs[ri % runs.length].start;
    for (final (b, length, midi) in notes) {
      final start = ((b + barOffset * 4) * _beat).round();
      final duration = (length * _beat).round() - 600;
      if (duration < 480) continue;
      var run = runs[ri % runs.length];
      if (sampledBass) {
        final rate = math.pow(2, (midi - 45) / 12).toDouble().clamp(.45, 2.0).toDouble();
        final need = (duration * rate).round();
        if (at + need > run.end) {
          ri++;
          run = runs[ri % runs.length];
          at = run.start;
        }
        add(bass, start, duration, at, role: 'bass', gain: gain, rate: rate);
        at += need;
      } else {
        if (at + duration > run.end) {
          ri++;
          run = runs[ri % runs.length];
          at = run.start;
        }
        final need = math.min(duration, run.length);
        add(bass, start, duration, at, role: 'bass', gain: gain, note: midi, span: need);
        at += need;
      }
    }
    return (ri, at);
  }

  void drums(int barFrom, int barTo, {bool snare = true, bool hats = true, double gain = 1}) {
    for (var beat = barFrom * 4; beat < barTo * 4; beat++) {
      final (kv, ks) = kit['kick']!;
      if (beat.isEven || !snare) {
        add(kv, beat * _beat, (.16 * _sampleRate).round(), ks, role: 'kick', gain: .95 * gain, rate: .55);
      }
      if (snare && beat.isOdd) {
        final (sv, ss) = kit['snare']!;
        add(sv, beat * _beat, (.12 * _sampleRate).round(), ss, role: 'snare', gain: .75 * gain);
      }
      if (hats) {
        final (hv, hs) = kit['hat']!;
        add(hv, beat * _beat + _beat ~/ 2, (.045 * _sampleRate).round(), hs, role: 'hat', gain: .35 * gain, rate: 1.6);
      }
    }
  }

  // -- effects ------------------------------------------------------------------

  void roll(_Voice v, int end, _Span syllable, {double gain = .8}) {
    final hits = <(int, int)>[];
    var t = end - 2 * _beat;
    for (final (length, step) in const [(_beat, _beat ~/ 2), (_beat ~/ 2, _beat ~/ 4), (_beat ~/ 2, _beat ~/ 8)]) {
      for (var k = 0; k < length ~/ step; k++) {
        hits.add((t + k * step, step));
      }
      t += length;
    }
    for (final (i, (at, step)) in hits.indexed) {
      final rate = math.pow(2, 7 * i / math.max(1, hits.length - 1) / 12).toDouble();
      add(v, at, (step * .8).round(), syllable.start, role: 'fx', gain: gain * (.6 + .4 * i / hits.length), rate: rate);
    }
  }

  void riser(_Voice v, int end, _Span region, {int beats = 4, double gain = .55}) {
    final duration = beats * _beat;
    add(v, end - duration, duration, region.start, role: 'fx', gain: gain, rate: .7, glide: 12, fadeIn: duration ~/ 2, fadeOut: 480);
  }

  void reverseSwell(_Voice v, int end, _Span region, {double beats = 1.5, double gain = .8}) {
    final duration = math.min((beats * _beat).round(), region.length);
    add(v, end - duration, duration, region.start, role: 'fx', gain: gain, reverse: true, fadeIn: (duration * .85).round(), fadeOut: 240);
  }

  void scratchFill(_Voice v, int start, _Span syllable, {int beats = 2, double gain = .8}) {
    final depth = math.min(.2, syllable.length / _sampleRate);
    add(v, start, beats * _beat, syllable.start, role: 'fx', gain: gain, scratch: _round(depth), scratchPeriod: _beat ~/ 2);
  }

  void stabs(_Voice v, _Span syllable, int barFrom, int bars, double root, {double gain = .22}) {
    for (var bar = barFrom; bar < barFrom + bars; bar++) {
      for (var beat = 0; beat < 4; beat++) {
        final at = bar * _bar + beat * _beat + _beat ~/ 2;
        for (final interval in const [0, 7, 12]) {
          add(v, at, (.16 * _sampleRate).round(), syllable.start, role: 'stab', gain: gain, note: root + interval, span: math.min(syllable.length, (.16 * _sampleRate).round()));
        }
      }
    }
  }

  T _choose<T>(List<T> options) => options[random.nextInt(options.length)];

  /// Clips that neither sing nor play bass, so they would otherwise only be
  /// heard as an introduction and a few chops.
  List<_Voice> get _cameos =>
      usable.where((v) => !singers.contains(v) && v != bass).toList();

  /// Each cameo clip plays whole and quietly behind the melody, one every
  /// other bar; the picture shows it as a corner sticker.
  void _backing(List<int> bars, {required int shortFrom}) {
    final cameos = _cameos;
    if (cameos.isEmpty) return;
    for (final (k, bar) in bars.indexed) {
      final v = cameos[k % cameos.length];
      final whole = v.whole;
      // bars with answering chops keep their last beat clear
      final limit = ((bar >= shortFrom ? 1.1 : 1.6) * _sampleRate).round();
      add(v, bar * _bar + _beat ~/ 2, math.min(whole.length, limit), whole.start,
          role: 'backing', gain: .38, fadeIn: 480, fadeOut: 2400);
    }
  }

  // -- song structures ----------------------------------------------------------

  void _introductions(int bars) {
    final order = [lead, ...others];
    var t = 0;
    // at least half a beat each, so six clips still all fit into one bar
    final slot = math.max(_beat ~/ 2, (bars * _bar - 3 * _sixteenth) ~/ math.max(1, order.length));
    for (final (k, v) in order.indexed) {
      if (t >= bars * _bar - _beat ~/ 2) break;
      if (k == 0) t += stutterHead(v, t, v.longest);
      final duration = phrase(v, t, v.longest, limit: math.min(1.4, (slot - 600) / _sampleRate));
      t = order.length > 3 ? t + slot : ((t + duration) / _beat).ceil() * _beat;
    }
  }

  void _melodyBars(int barOffset, int barCount, Map<String, (int, int?)> cursors, {int chunkBeats = 8}) {
    if (!melodic) {
      // Rhythm only: the lead answers in its own words, unpitched.
      for (var bar = barOffset; bar < barOffset + barCount; bar += 2) {
        phrase(lead, bar * _bar, lead.longest, gain: .9, limit: 1.2);
      }
      return;
    }
    final beats = barCount * 4;
    for (var chunk = 0; chunk * chunkBeats < beats; chunk++) {
      final singer = singers[chunk % singers.length];
      final part = [
        for (final n in _sungBy(singer))
          if (n.$1 >= chunk * chunkBeats && n.$1 < (chunk + 1) * chunkBeats && n.$1 < beats) n,
      ];
      cursors[singer.id] = syllableLine(singer, cursors[singer.id] ?? (0, null), part, barOffset, .95);
    }
  }

  void buildLong() {
    final cursors = <String, (int, int?)>{};
    (int, int?) bassCursor = (0, null);
    _introductions(2);
    drums(1, 2, snare: false, hats: false, gain: .7);
    drums(2, 4);
    if (melodic) {
      bassCursor = bassPart(bassCursor, [for (final n in bassLine) if (n.$1 < 8) n], 2, .6);
    }
    tailEcho(others.isNotEmpty ? others.last : lead, 3 * _bar + 2 * _beat, (others.isNotEmpty ? others.last : lead).longest, times: 4);
    drums(4, 12);
    _melodyBars(4, 8, cursors);
    if (melodic) {
      bassCursor = bassPart(bassCursor, bassLine, 4, .55);
    }
    if (melodic) _backing(const [5, 7, 9, 11], shortFrom: 8);
    // the clips with the least to do answer first
    final cameos = _cameos;
    final answer = [
      ...cameos,
      ...others.where((v) => !singers.contains(v) && !cameos.contains(v)),
    ];
    final answers = answer.isNotEmpty ? answer : (others.isNotEmpty ? others : [lead]);
    for (final (k, bar) in [8, 9, 10, 11].indexed) {
      final v = answers[k % answers.length];
      stutterHead(v, bar * _bar + 3 * _beat, v.longest, times: 4, gain: .55);
    }
    // Break: the longest phrase raw and up front.
    final star = usable.reduce((a, b) => b.longest.length > a.longest.length ? b : a);
    final (kickVoice, kickSource) = kit['kick']!;
    add(kickVoice, 12 * _bar, (.16 * _sampleRate).round(), kickSource, role: 'kick', gain: .9, rate: .55);
    final said = phrase(star, 12 * _bar + _beat ~/ 2, star.longest, limit: 2.4);
    tailEcho(star, 12 * _bar + _beat ~/ 2 + said, star.longest, gain: .8);
    if (melodic) {
      bassCursor = bassPart(bassCursor, [for (final n in bassLine) if (n.$1 >= 24 && n.$1 < 32) (n.$1 - 24, n.$2, n.$3)], 12, .3);
    }
    // Climax: the hook again, full kit, everyone stutters at the end.
    drums(14, 16);
    if (melodic) {
      final singer = singers.last;
      syllableLine(singer, cursors[singer.id] ?? (0, null), [for (final n in _sungBy(singer)) if (n.$1 < 8) n], 14, 1);
      bassPart(bassCursor, [for (final n in bassLine) if (n.$1 < 8) n], 14, .55);
    }
    final order = [lead, ...others];
    for (final (k, v) in order.indexed) {
      stutterHead(v, 15 * _bar + 2 * _beat + (k * _sixteenth * 2) % (2 * _beat), v.longest, times: 2, gain: .7);
    }
    sections.addAll(const [
      SongSection(fromBar: 0, toBar: 2, energy: 'calm'),
      SongSection(fromBar: 2, toBar: 8, energy: 'mid'),
      SongSection(fromBar: 8, toBar: 12, energy: 'high'),
      SongSection(fromBar: 12, toBar: 14, energy: 'calm'),
      SongSection(fromBar: 14, toBar: 16, energy: 'high'),
    ]);
    _effects(intoMelody: 4 * _bar, intoBreak: 12 * _bar, breakBars: 2, intoClimax: 14 * _bar, stabBar: 8, climaxBar: 14);
  }

  void buildShort() {
    final cursors = <String, (int, int?)>{};
    (int, int?) bassCursor = (0, null);
    _introductions(1);
    drums(1, 2);
    if (melodic) {
      bassCursor = bassPart(bassCursor, [for (final n in bassLine) if (n.$1 < 4) n], 1, .6);
    }
    drums(2, 6);
    _melodyBars(2, 4, cursors);
    if (melodic) {
      bassCursor = bassPart(bassCursor, [for (final n in bassLine) if (n.$1 < 16) n], 2, .55);
    }
    if (melodic) _backing(const [3, 5], shortFrom: 0);
    drums(6, 8);
    if (melodic) {
      final singer = singers.last;
      syllableLine(singer, cursors[singer.id] ?? (0, null), [for (final n in _sungBy(singer)) if (n.$1 < 8) n], 6, 1);
      bassPart(bassCursor, [for (final n in bassLine) if (n.$1 < 8) n], 6, .55);
    }
    final order = [lead, ...others];
    for (final (k, v) in order.indexed) {
      stutterHead(v, 7 * _bar + 2 * _beat + (k * _sixteenth * 2) % (2 * _beat), v.longest, times: 2, gain: .7);
    }
    sections.addAll(const [
      SongSection(fromBar: 0, toBar: 2, energy: 'calm'),
      SongSection(fromBar: 2, toBar: 6, energy: 'mid'),
      SongSection(fromBar: 6, toBar: 8, energy: 'high'),
    ]);
    _effects(intoMelody: 2 * _bar, intoBreak: null, breakBars: 0, intoClimax: 6 * _bar, stabBar: 4, climaxBar: 6);
  }

  void _effects({required int intoMelody, required int? intoBreak, required int breakBars, required int intoClimax, required int stabBar, required int climaxBar}) {
    final syllableOf = {for (final v in voices) v.id: v.syllables.first};
    final longClip = usable.reduce((a, b) => b.longest.length > a.longest.length ? b : a);
    void into(String slot, int end) {
      switch (slot) {
        case 'roll':
          roll(lead, end, syllableOf[lead.id]!);
        case 'riser':
          riser(longClip, end, longClip.longest);
        default:
          reverseSwell(lead, end, lead.longest);
      }
    }

    into(_choose(const ['roll', 'riser', 'reverse']), intoMelody);
    into(_choose(const ['roll', 'reverse', 'riser']), intoClimax);
    if (intoBreak != null) {
      final breakIn = _choose(const ['tapestop', 'scratch']);
      if (breakIn == 'tapestop') {
        masterEffects.add(MasterEffect(type: 'tapestop', startSample: intoBreak - _beat, durationSamples: _beat));
      } else {
        scratchFill(lead, intoBreak - 2 * _beat, syllableOf[lead.id]!);
      }
      // A tape stop usually opens into a sweep.
      final inBreak = breakIn == 'tapestop'
          ? (random.nextDouble() < .8 ? 'sweep' : 'gate')
          : _choose(const ['sweep', 'gate']);
      if (inBreak == 'sweep') {
        masterEffects.add(MasterEffect(type: 'sweep', startSample: intoBreak, durationSamples: breakBars * _bar));
      } else {
        for (var i = 0; i < events.length; i++) {
          final e = events[i];
          if (e.role == 'phrase' && e.destinationStartSample >= intoBreak && e.destinationStartSample < intoBreak + _bar) {
            events[i] = _copy(e, gate: 4);
          }
        }
      }
    }
    if (melodic && random.nextDouble() < .6) {
      final stabVoice = usable.where((v) => !singers.contains(v) && v.syllables.any((s) => s.midi != null)).firstOrNull;
      if (stabVoice != null) {
        final syllable = stabVoice.syllables.firstWhere((s) => s.midi != null);
        final root = bassLine.isEmpty ? 48.0 : bassLine.first.$3 + 12;
        stabs(stabVoice, syllable, stabBar, 2, root);
      }
    }
    if (random.nextDouble() < .6) {
      scratchFill(lead, (climaxBar + 1) * _bar, syllableOf[lead.id]!, gain: .6);
    }
    // Second wave: each optional, so no two videos stack the same set.
    final intro = events.where((e) => e.role == 'phrase' && e.destinationStartSample < 2 * _bar && e.assetId != lead.id).toList();
    if (intro.isNotEmpty && random.nextDouble() < .5) {
      final pick = intro[random.nextInt(intro.length)];
      final rate = _choose(const [1.45, 0.7]);
      final index = events.indexOf(pick);
      final voice = voices.firstWhere((v) => v.id == pick.assetId);
      final need = (pick.durationSamples * rate).ceil() + 2;
      if (need <= voice.end - voice.start) {
        events.removeAt(index);
        add(voice, pick.destinationStartSample, pick.durationSamples, pick.sourceStartSample, role: 'phrase', gain: pick.gain, rate: rate);
      }
    }
    if (melodic && random.nextDouble() < .4) {
      final from = climaxBar >= 14 ? 8 * _bar : 4 * _bar;
      final bounce = events.where((e) => e.role == 'melody' && e.destinationStartSample >= from && e.destinationStartSample < from + 2 * _bar && (e.targetMidiNote != null || e.rate != null)).toList();
      for (final (j, e) in bounce.indexed) {
        if (j.isOdd) {
          final index = events.indexOf(e);
          events[index] = e.targetMidiNote != null
              ? _copy(e, note: math.min(100.0, e.targetMidiNote! + 12))
              : _copy(e, rate: math.min(4.0, e.rate! * 2));
        }
      }
    }
    final halftime = random.nextDouble() < .35;
    if (halftime) {
      events.removeWhere((e) => (e.role == 'kick' || e.role == 'snare' || e.role == 'hat') && e.destinationStartSample >= climaxBar * _bar && e.destinationStartSample < (climaxBar + 1) * _bar);
      final (kv, ks) = kit['kick']!;
      final (sv, ss) = kit['snare']!;
      add(kv, climaxBar * _bar, (.16 * _sampleRate).round(), ks, role: 'kick', gain: .95, rate: .55);
      add(sv, climaxBar * _bar + 2 * _beat, (.14 * _sampleRate).round(), ss, role: 'snare', gain: .85);
      masterEffects.add(MasterEffect(type: 'halftime', startSample: climaxBar * _bar, durationSamples: _bar));
    }
    if (random.nextDouble() < (halftime ? .3 : .5)) {
      final (from, length) = _choose([(intoMelody, 4 * _bar), (climaxBar * _bar, 2 * _bar)]);
      final kicks = [
        for (final e in events)
          if (e.role == 'kick' && e.destinationStartSample >= from && e.destinationStartSample < from + length) e.destinationStartSample,
      ]..sort();
      if (kicks.isNotEmpty && from + length <= total) {
        masterEffects.add(MasterEffect(type: 'sidechain', startSample: from, durationSamples: length, kickSamples: kicks.take(128).toList()));
      }
    }
    if (intoBreak != null && random.nextDouble() < .5) {
      final said = events.where((e) => e.role == 'phrase' && e.destinationStartSample >= intoBreak && e.destinationStartSample < intoBreak + _bar).toList();
      for (final e in said) {
        for (var k = 1; k <= 3; k++) {
          final at = e.destinationStartSample + e.durationSamples + k * (3 * _beat ~/ 4);
          if (at < total) {
            events.add(_copy(e, start: at, gain: e.gain * math.pow(.5, k).toDouble(), role: 'echo'));
          }
        }
      }
    }
    if (intoBreak != null && random.nextDouble() < .35) {
      masterEffects.add(MasterEffect(type: 'bitcrush', startSample: intoBreak - _bar, durationSamples: _bar - _beat));
    }
  }

  SoundEvent _copy(SoundEvent e, {int? gate, double? note, double? rate, int? start, double? gain, String? role}) {
    final json = e.toJson();
    if (gate != null) json['gate'] = gate;
    if (note != null) json['targetMidiNote'] = note;
    if (rate != null) json['rate'] = rate;
    if (gain != null) json['gain'] = gain.clamp(0.0, 1.0);
    if (role != null) {
      json['role'] = role;
      json['partIndex'] = _parts[role] ?? 0;
    }
    if (start != null) {
      json['destinationStartSample'] = start;
      final duration = math.min(e.durationSamples, total - start);
      json['durationSamples'] = duration;
      json['fades'] = {
        'fadeInSamples': math.min(e.fades.fadeInSamples, duration ~/ 4),
        'fadeOutSamples': math.min(e.fades.fadeOutSamples, duration ~/ 4),
      };
    }
    return SoundEvent.fromJson(json);
  }

  // -- output -------------------------------------------------------------------

  Arrangement finish({required ArrangementStyle style, required MelodyTemplate melodyTemplate}) {
    // Stay inside the event budget: thin hats first, then stabs, then chops.
    for (final role in const ['hat', 'stab', 'echo', 'chop']) {
      if (events.length <= 500) break;
      var drop = events.length - 500;
      events.removeWhere((e) {
        if (drop > 0 && e.role == role) {
          drop--;
          return true;
        }
        return false;
      });
    }
    final ordered = events.indexed.toList()
      ..sort((a, b) {
        final d = a.$2.destinationStartSample.compareTo(b.$2.destinationStartSample);
        return d == 0 ? a.$1.compareTo(b.$1) : d;
      });
    final sound = [for (final entry in ordered) entry.$2];
    final video = [
      for (final e in sound)
        VideoEvent(
          assetId: e.assetId,
          destinationStartSample: e.destinationStartSample,
          durationSamples: e.durationSamples,
          sourceVideoStartTime: RationalTime(e.sourceStartSample, _sampleRate),
          sourceDurationSamples: e.sourceDurationSamples,
          crop: NormalizedCrop.fullFrame,
          loopMode: e.durationSamples > e.effectiveSourceDurationSamples && !e.hasMotion
              ? VideoLoopMode.loop
              : VideoLoopMode.once,
          reverse: e.reverse,
          partIndex: e.partIndex,
        ),
    ];
    final (kickVoice, _) = kit['kick']!;
    return Arrangement(
      templateId: 'mad-${total ~/ _sampleRate}-${melodyTemplate.name}',
      templateVersion: 1,
      analysisVersion: 1,
      rendererVersion: 1,
      seed: seed,
      style: style,
      melodyTemplate: melodyTemplate,
      songRoles: SongRoles(
        beat: kickVoice.id,
        bass: melodic ? bass.id : null,
        melody: melodic ? lead.id : null,
      ),
      sourceAssetIds: clips.map((c) => c.assetId).toList(),
      unusableAssetIds: clips.where((c) => !c.isUsable).map((c) => c.assetId).toList(),
      events: sound,
      videoEvents: video,
      totalSamples: total,
      performanceMode: PerformanceMode.mad,
      masterEffects: masterEffects,
      sections: sections,
    );
  }
}
