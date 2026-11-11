// Engine_Quartz: norns engine around the Quartz granular UGen.
// Source modes: 0 grains (live input), 1 synth drone, 2 track (input pitch
// plays the synth voice), 3 midi (keyboard plays the synth voice).

Engine_Quartz : CroneEngine {
	var synth, ampBus, noteBus, sampleBuf;
	var inAmpBus, scopeBuf, phaseBus, scopeRoutine, matron;
	var scopeOn = false, scopeBusy = false, busyTicks = 0;

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
			amp_bus=0, note_bus=0, samp_buf=0, use_sample=0, samp_speed=1,
			in_amp_bus=0, scope_buf=0, phase_bus=0;

			var live = [In.ar(in_l), In.ar(in_r)];
			var samp = PlayBuf.ar(2, samp_buf, BufRateScale.kr(samp_buf) * samp_speed, loop: 1);
			var input = Select.ar(use_sample, [live, samp]);
			var monoIn = Mix(input) * 0.5;
			var tracked, hasFreq, amp, trackNote, trackGate, semis, vca, sig, phase;

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
			Out.kr(note_bus, Select.kr(source >= 3, [trackNote, note]) + (octave * 12));
			// for the screen: the level going onto the tape, and a rolling
			// window of the output for the scope
			Out.kr(in_amp_bus, Amplitude.kr(Mix(input) * 0.5 * gain, 0.005, 0.1));
			phase = Phasor.ar(0, 1, 0, BufFrames.kr(scope_buf));
			BufWr.ar(Mix(sig) * 0.5, scope_buf, phase);
			Out.kr(phase_bus, A2K.kr(phase));
		}).add;

		// placeholder until a sample file is loaded
		sampleBuf = Buffer.alloc(context.server, 64, 2);
		ampBus = Bus.control(context.server);
		noteBus = Bus.control(context.server);
		inAmpBus = Bus.control(context.server);
		phaseBus = Bus.control(context.server);
		scopeBuf = Buffer.alloc(context.server, 2048, 1);
		matron = NetAddr("127.0.0.1", 10111);
		context.server.sync;

		synth = Synth.new(\quartz, [
			\amp_bus, ampBus.index,
			\samp_buf, sampleBuf.bufnum,
			\note_bus, noteBus.index,
			\in_amp_bus, inAmpBus.index,
			\scope_buf, scopeBuf.bufnum,
			\phase_bus, phaseBus.index,
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
			\threshold, \dry_level, \trig, \clocked, \use_sample, \samp_speed
		].do({ arg key;
			this.addCommand(key, "f", { arg msg; synth.set(key, msg[1]); });
		});

		// load a sound file (mono files are doubled to stereo)
		this.addCommand(\load_sample, "s", { arg msg;
			var path = msg[1].asString;
			var file = SoundFile.openRead(path);
			if (file.notNil) {
				var chans = if (file.numChannels > 1) { [0, 1] } { [0, 0] };
				file.close;
				Buffer.readChannel(context.server, path, channels: chans, action: { arg buf;
					var old = sampleBuf;
					sampleBuf = buf;
					synth.set(\samp_buf, buf.bufnum);
					old.free;
				});
			} {
				("quartz: could not open " ++ path).postln;
			};
		});

		// scope: about 15 snapshots a second, only while a synth source is on.
		// each snapshot starts on a rising zero crossing so the trace holds still
		this.addCommand(\scope, "f", { arg msg; scopeOn = msg[1] > 0 });
		scopeRoutine = Routine({
			loop {
				// if a reply ever goes missing, don't stall the scope
				if (scopeBusy) { busyTicks = busyTicks + 1; if (busyTicks > 15) { scopeBusy = false } };
				if (scopeOn and: { scopeBusy.not }) {
					var wp = phaseBus.getSynchronous.asInteger;
					scopeBusy = true;
					busyTicks = 0;
					scopeBuf.getn(0, 2048, { arg data;
						var a = data.rotate(wp.neg);   // oldest first
						var start = 600, pts;
						// skip the oldest samples, which may be overwritten by now
						(600..1023).do({ arg i;
							if ((start == 600) and: { a[i] <= 0 } and: { a[i + 1] > 0 }) { start = i };
						});
						pts = Array.fill(113, { arg k;
							(a[start + (k * 1024 / 113).floor] * 2.5).clip(-1, 1)
						});
						matron.sendMsg("/quartz/scope", *pts);
						scopeBusy = false;
					});
				};
				(1 / 15).wait;
			}
		}).play(SystemClock);

		this.addPoll("amp", { ampBus.getSynchronous });
		this.addPoll("in_amp", { inAmpBus.getSynchronous });
		this.addPoll("note", { noteBus.getSynchronous });
	}

	free {
		scopeRoutine.stop;
		scopeBuf.free;
		inAmpBus.free;
		phaseBus.free;
		sampleBuf.free;
		ampBus.free;
		noteBus.free;
		synth.free;
	}
}
