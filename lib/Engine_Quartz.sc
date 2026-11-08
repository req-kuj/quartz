// Engine_Quartz: norns engine around the Quartz granular UGen.
// Source modes: 0 grains (live input), 1 synth drone, 2 track (input pitch
// plays the synth voice), 3 midi (keyboard plays the synth voice).

Engine_Quartz : CroneEngine {
	var synth, ampBus, noteBus;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		SynthDef(\quartz, {
			arg in_l, in_r, out,
			time=0.5, size=0.5, shape=0.5, pitch=0, density=0.75,
			time_rnd=0, size_rnd=0, shape_rnd=0, pitch_rnd=0,
			feedback=0.2, drywet=0.6, reverb=0.4,
			freeze=0, seed=2, quality=3, mono=1, gain=1,
			source=0, note=48, gate=0, octave=0, glide=1, release=1.5,
			threshold=0.02, dry_level=0, trig=0, clocked=0,
			amp_bus=0, note_bus=0;

			var input = [In.ar(in_l), In.ar(in_r)];
			var monoIn = Mix(input) * 0.5;
			var tracked, hasFreq, amp, trackNote, trackGate, semis, vca, sig;

			// Pitch tracking (mode 2).
			# tracked, hasFreq = Pitch.kr(monoIn, minFreq: 30, maxFreq: 1600,
				ampThreshold: 0.01, median: 7);
			amp = Amplitude.kr(monoIn, 0.01, 0.2);
			trackGate = (amp > threshold) * hasFreq;
			trackNote = Gate.kr(tracked.cpsmidi, trackGate);
			trackNote = Select.kr(glide, [trackNote.round, trackNote]);
			trackNote = Lag.kr(trackNote, glide * 0.03);

			semis = Select.kr(source, [
				pitch,
				pitch,
				trackNote - 48 + (octave * 12) + pitch,
				note - 48 + (octave * 12) + pitch
			]);

			sig = Quartz.ar(input * gain,
				time, size, shape, semis, density,
				time_rnd, size_rnd, shape_rnd, pitch_rnd,
				feedback, drywet, reverb,
				freeze, seed, trig, clocked,
				quality, source > 0, mono, 1);

			// Played modes get an envelope so the voice follows the notes.
			vca = Select.kr(source.clip(0, 3), [
				DC.kr(1),
				DC.kr(1),
				EnvGen.kr(Env.asr(0.01, 1, release), trackGate),
				EnvGen.kr(Env.asr(0.005, 1, release), gate)
			]);
			sig = (sig * vca) + (input * dry_level * (source >= 2));
			Out.ar(out, sig);
			// for crow outputs: loudness of the cloud and the followed note
			Out.kr(amp_bus, Amplitude.kr(Mix(sig) * 0.5, 0.01, 0.15));
			Out.kr(note_bus, trackNote + (octave * 12));
		}).add;

		ampBus = Bus.control(context.server);
		noteBus = Bus.control(context.server);
		context.server.sync;

		synth = Synth.new(\quartz, [
			\amp_bus, ampBus.index,
			\note_bus, noteBus.index,
			\in_l, context.in_b[0].index,
			\in_r, context.in_b[1].index,
			\out, context.out_b.index
		], context.xg);

		[
			\time, \size, \shape, \pitch, \density,
			\time_rnd, \size_rnd, \shape_rnd, \pitch_rnd,
			\feedback, \drywet, \reverb,
			\freeze, \seed, \quality, \mono, \gain,
			\source, \note, \gate, \octave, \glide, \release,
			\threshold, \dry_level, \trig, \clocked
		].do({ arg key;
			this.addCommand(key, "f", { arg msg; synth.set(key, msg[1]); });
		});

		this.addPoll("amp", { ampBus.getSynchronous });
		this.addPoll("note", { noteBus.getSynchronous });
	}

	free {
		ampBus.free;
		noteBus.free;
		synth.free;
	}
}
