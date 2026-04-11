/* Based on:
- https://github.com/webrtc/samples/tree/gh-pages/src/content/devices/input-output
- https://github.com/webrtc/samples/tree/gh-pages/src/content/getusermedia/volume
*/

"use strict";

const instantMeter = document.querySelector("#instant meter");
const slowMeter = document.querySelector("#slow meter");
const clipMeter = document.querySelector("#clip meter");

const instantValueDisplay = document.querySelector("#instant .value");
const slowValueDisplay = document.querySelector("#slow .value");
const clipValueDisplay = document.querySelector("#clip .value");

try {
	window.AudioContext = window.AudioContext || window.webkitAudioContext;
	window.audioContext = new AudioContext();
} catch (e) {
	alert("Web Audio API not supported.");
}

window.soundMeter = new SoundMeter(window.audioContext);

const videoElement = document.querySelector("video");
const audioInputSelect = document.querySelector("select#audioSource");
const audioOutputSelect = document.querySelector("select#audioOutput");
const videoSelect = document.querySelector("select#videoSource");
const selectors = [audioInputSelect, audioOutputSelect, videoSelect];
let hasMic = false;
let hasCamera = false;
let openMic = undefined;
let openCamera = undefined;
let hasPermission = false;

audioOutputSelect.disabled = !("sinkId" in HTMLMediaElement.prototype);

function getDevices() {
	navigator.mediaDevices
		.enumerateDevices()
		.then(gotDevices)
		.catch(handleError);
}

function gotDevices(deviceInfos) {
	console.log("gotDevices", deviceInfos);
	hasMic = false;
	hasCamera = false;
	hasPermission = false;
	// Handles being called several times to update labels. Preserve values.
	const values = selectors.map((select) => select.value);
	selectors.forEach((select) => {
		while (select.firstChild) {
			select.removeChild(select.firstChild);
		}
	});
	for (let i = 0; i !== deviceInfos.length; ++i) {
		const deviceInfo = deviceInfos[i];
		if (deviceInfo.deviceId == "") {
			continue;
		}
		// If we get at least one deviceId, that means user has granted user
		// media permissions.
		hasPermission = true;
		const option = document.createElement("option");
		option.value = deviceInfo.deviceId;
		if (deviceInfo.kind === "audioinput") {
			hasMic = true;
			option.text =
				deviceInfo.label || `microphone ${audioInputSelect.length + 1}`;
			audioInputSelect.appendChild(option);
		} else if (deviceInfo.kind === "audiooutput") {
			option.text =
				deviceInfo.label || `speaker ${audioOutputSelect.length + 1}`;
			audioOutputSelect.appendChild(option);
		} else if (deviceInfo.kind === "videoinput") {
			hasCamera = true;
			option.text =
				deviceInfo.label || `camera ${videoSelect.length + 1}`;
			videoSelect.appendChild(option);
		} else {
			console.log("Some other kind of source/device: ", deviceInfo);
		}
	}
	selectors.forEach((select, selectorIndex) => {
		if (
			Array.prototype.slice
				.call(select.childNodes)
				.some((n) => n.value === values[selectorIndex])
		) {
			select.value = values[selectorIndex];
		}
	});
	start();
}

// Attach audio output device to video element using device/sink ID.
function attachSinkId(element, sinkId) {
	if (typeof element.sinkId !== "undefined") {
		element
			.setSinkId(sinkId)
			.then(() => {
				console.log(`Success, audio output device attached: ${sinkId}`);
			})
			.catch((error) => {
				let errorMessage = error;
				if (error.name === "SecurityError") {
					errorMessage = `You need to use HTTPS for selecting audio output device: ${error}`;
				}
				console.error(errorMessage);
				// Jump back to first output device in the list as it's the default.
				audioOutputSelect.selectedIndex = 0;
			});
	} else {
		console.warn("Browser does not support output device selection.");
	}
}

function changeAudioDestination() {
	const audioDestination = audioOutputSelect.value;
	attachSinkId(videoElement, audioDestination);
}

let meterRefresh = null;

function gotStream(stream) {
	window.stream = stream; // make stream available to console
	videoElement.srcObject = stream;
	if (stream.getVideoTracks()[0]) {
		openCamera = stream.getVideoTracks()[0].getSettings().deviceId;
	}
	if (stream.getAudioTracks()[0]) {
		openMic = stream.getAudioTracks()[0].getSettings().deviceId;
	}

	window.soundMeter.connectToSource(stream, function (e) {
		if (e) {
			alert(e);
			return;
		}
		meterRefresh = setInterval(() => {
			instantMeter.value = instantValueDisplay.innerText =
				window.soundMeter.instant.toFixed(2);
			slowMeter.value = slowValueDisplay.innerText =
				window.soundMeter.slow.toFixed(2);
			clipMeter.value = clipValueDisplay.innerText =
				window.soundMeter.clip;
		}, 200);
	});

	// Refresh list in case labels have become available
	return getDevices();
}

function handleError(error) {
	console.log(
		"navigator.MediaDevices.getUserMedia error: ",
		error.message,
		error.name
	);
}

function start() {
	const audioSource = audioInputSelect.value || undefined;
	const videoSource = videoSelect.value || undefined;
	// Don't open the same devices again.
	if (hasPermission && openMic == audioSource && openCamera == videoSource) {
		return;
	}
	// Close existng streams.
	if (window.stream) {
		window.stream.getTracks().forEach((track) => {
			track.stop();
		});
		openCamera = undefined;
		openMic = undefined;
		window.soundMeter.stop();
	}
	const constraints = {
		audio: true,
		video: true,
	};
	if (hasMic) {
		constraints["audio"] = {
			deviceId: audioSource ? { exact: audioSource } : undefined,
		};
	}
	if (hasCamera) {
		constraints["video"] = {
			deviceId: videoSource ? { exact: videoSource } : undefined,
		};
	}
	console.log("start", constraints);
	if (!hasPermission || hasCamera || hasMic) {
		navigator.mediaDevices
			.getUserMedia(constraints)
			.then(gotStream)
			.catch(handleError);
	}
}

audioInputSelect.onchange = start;
audioOutputSelect.onchange = changeAudioDestination;
videoSelect.onchange = start;
navigator.mediaDevices.ondevicechange = getDevices;

getDevices();

// Meter class that generates a number correlated to audio volume.
// The meter class itself displays nothing, but it makes the
// instantaneous and time-decaying volumes available for inspection.
// It also reports on the fraction of samples that were at or near
// the top of the measurement range.
function SoundMeter(context) {
	this.context = context;
	this.instant = 0.0;
	this.slow = 0.0;
	this.clip = 0.0;
	this.node = null;
}

SoundMeter.prototype.connectToSource = async function (stream, callback) {
	console.log("SoundMeter connecting");
	try {
		await this.context.audioWorklet.addModule("volume-meter-processor.js");
		this.mic = this.context.createMediaStreamSource(stream);
		this.node = new AudioWorkletNode(
			this.context,
			"volume-meter-processor"
		);
		this.node.port.onmessage = (event) => {
			const { instant, clip } = event.data;
			this.instant = instant;
			this.clip = clip;
			this.slow = 0.95 * this.slow + 0.05 * this.instant;
		};
		this.mic.connect(this.node);
		if (typeof callback !== "undefined") {
			callback(null);
		}
	} catch (e) {
		console.error(e);
		if (typeof callback !== "undefined") {
			callback(e);
		}
	}
};

SoundMeter.prototype.stop = function () {
	console.log("SoundMeter stopping");
	this.mic.disconnect();
	this.node.disconnect();
};
