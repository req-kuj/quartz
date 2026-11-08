// Quartz: granular texture UGen built on the open-source Beads DSP
// by Emilie Gillet (MIT).

Quartz : MultiOutUGen {
	*ar { arg in, time=0.5, size=0.5, shape=0.5, pitch=0, density=0.75,
		timeRnd=0, sizeRnd=0, shapeRnd=0, pitchRnd=0,
		feedback=0, drywet=0.5, reverb=0.3,
		freeze=0, seed=2, trig=0, clocked=0,
		quality=3, synth=0, mono=0, gain=1;
		var ins = in.asArray;
		var inL = ins[0];
		var inR = ins[1] ? inL;
		^this.multiNew('audio', inL, inR, time, size, shape, pitch, density,
			timeRnd, sizeRnd, shapeRnd, pitchRnd,
			feedback, drywet, reverb,
			freeze, seed, trig, clocked,
			quality, synth, mono, gain);
	}

	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate);
	}
}
