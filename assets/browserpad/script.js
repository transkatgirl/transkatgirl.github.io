var textbox = document.querySelector("#textbox");
var timeoutID = null;

// Automatically load/save cache in local storage when opening and closing the page
textbox.value = localStorage.getItem("browserpad") || "";
textbox.setSelectionRange(textbox.value.length, textbox.value.length); // Place caret at end of content
function storeLocally() {
	localStorage.setItem("browserpad", textbox.value);
}
window.beforeunload = storeLocally;
textbox.onchange = storeLocally;

// Allow inputting tabs in the textarea instead of changing focus to the next element
// (must use onkeydown to prevent default behavior of moving focus)
textbox.onkeydown = function (event) {
	if (event.key === "Tab") {
		event.preventDefault();
		var text = this.value,
			s = this.selectionStart,
			e = this.selectionEnd;
		this.value = text.substring(0, s) + "\t" + text.substring(e);
		this.selectionStart = this.selectionEnd = s + 1;
	}
};

textbox.onkeyup = function () {
	// Auto-save to local storage (at most once per second)
	window.clearTimeout(timeoutID);
	timeoutID = window.setTimeout(storeLocally, 1000);
};

// Toggle spell-checking
textbox.spellcheck = true;
document.onkeydown = function (event) {
	if (event.ctrlKey) {
		if (event.key === "t") {
			textbox.spellcheck = !textbox.spellcheck;
			event.preventDefault();
		}
	}
};
