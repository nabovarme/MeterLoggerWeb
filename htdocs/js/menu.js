// List of menu items
const menuItems = [
	{ text: "Meters", href: "/index.html" },
	{ text: "Map", href: "/map" },
	{ text: "Network", href: "/network.html" },
	{ text: "Payments pending", href: "/payments_pending.html" },
	{ text: "SMS sent", href: "/sms_sent.html" },
	{ text: "Alarms", href: "/alarms.html" },
	{ text: "Wi-Fi pending", href: "/wifi_pending.html" },
	{ text: "User log", href: "/users.epl" },
	{ text: "Valve control", href: "/valve_control.epl" },
	{ separator: true },
	{ text: "Logout", href: "/logout" }
];

let typeAheadBuffer = "";
let typeAheadTimer;

// Insert burger menu and floating menu
function insertMenu() {
	const burger = document.createElement("button");
	burger.className = "burger";

	// Hamburger icon text
	burger.setAttribute("aria-label", "Toggle menu");
	burger.setAttribute("aria-expanded", "false");
	burger.innerText = "☰";

	// Toggle menu visibility on burger click
	burger.onclick = toggleMenu;

	const menu = document.createElement("nav");
	menu.id = "menu";
	menu.className = "floating-menu";
	menu.setAttribute("aria-hidden", "true");

	// Build menu items
	menuItems.forEach(item => {
		if (item.separator) {
			const hr = document.createElement("hr");
			hr.style.border = "0";
			hr.style.height = "1px";
			hr.style.backgroundColor = "#555";
			hr.style.margin = "10px 0";
			menu.appendChild(hr);
		} else {
			const a = document.createElement("a");
			a.href = item.href;
			a.dataset.text = item.text; // keep original text for highlighting
			a.innerHTML = item.text;
			a.tabIndex = -1;
			a.addEventListener("click", () => closeMenu());
			menu.appendChild(a);
		}
	});

	// Append burger and menu to the document body
	document.body.appendChild(burger);
	document.body.appendChild(menu);

	// Close menu when clicking outside
	document.addEventListener("click", function (e) {
		if (!menu.contains(e.target) && !burger.contains(e.target)) {
			closeMenu();
		}
	});

	// Global keydown listener
	document.addEventListener("keydown", function (e) {
		const active = document.activeElement;
		if (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable) return;

		const menuEl = document.getElementById("menu");
		const links = Array.from(menuEl.querySelectorAll("a"));

		// Arrow navigation
		if (menuEl.classList.contains("show")) {
			let index = links.indexOf(active);
			if (e.key === "ArrowDown") {
				e.preventDefault();
				index = (index + 1) % links.length;
				links[index].focus();
				return;
			}
			if (e.key === "ArrowUp") {
				e.preventDefault();
				index = (index - 1 + links.length) % links.length;
				links[index].focus();
				return;
			}
			if (e.key === "Escape") {
				e.preventDefault();
				closeMenu();
				return;
			}
			if (e.key === "Enter" && links.includes(active)) {
				e.preventDefault();
				active.click();
				return;
			}
		}

		// Only single-character keys for type-ahead
		if (e.key.length !== 1) return;

		e.preventDefault();

		// Open menu automatically
		if (!menuEl.classList.contains("show")) toggleMenu();

		// Update type-ahead buffer
		typeAheadBuffer += e.key.toLowerCase();
		clearTimeout(typeAheadTimer);
		typeAheadTimer = setTimeout(() => {
			typeAheadBuffer = "";
			// Reset highlights
			links.forEach(link => {
				link.innerHTML = link.dataset.text;
			});
		}, 800);

		// Find matching item
		let matched = links.find(link => link.dataset.text.toLowerCase().startsWith(typeAheadBuffer));

		// Wrap-around: if no match, start from top
		if (!matched) {
			matched = links.find(link => link.dataset.text.toLowerCase().startsWith(typeAheadBuffer));
		}

		if (matched) {
			matched.focus();
			// Highlight matched portion
			const original = matched.dataset.text;
			const matchLength = typeAheadBuffer.length;
			matched.innerHTML = `<span class="highlight">${original.slice(0, matchLength)}</span>${original.slice(matchLength)}`;
			// Reset other links
			links.forEach(link => {
				if (link !== matched) link.innerHTML = link.dataset.text;
			});
		}
	});
}

// Toggle menu visibility
function toggleMenu() {
	const menuEl = document.getElementById("menu");
	const burger = document.querySelector(".burger");
	if (!menuEl || !burger) return;

	const isOpen = menuEl.classList.toggle("show");
	menuEl.setAttribute("aria-hidden", !isOpen);
	burger.setAttribute("aria-expanded", isOpen);

	menuEl.querySelectorAll("a").forEach(link => {
		link.tabIndex = isOpen ? 0 : -1;
	});

	if (isOpen) {
		const links = Array.from(menuEl.querySelectorAll("a"));
		if (links.length) links[0].focus();
	}
}

// Close menu
function closeMenu() {
	const menuEl = document.getElementById("menu");
	const burger = document.querySelector(".burger");
	if (!menuEl || !burger) return;

	menuEl.classList.remove("show");
	menuEl.setAttribute("aria-hidden", "true");
	burger.setAttribute("aria-expanded", "false");

	menuEl.querySelectorAll("a").forEach(link => {
		link.tabIndex = -1;
		link.innerHTML = link.dataset.text; // reset highlight
	});
}

// Initialize menu
document.addEventListener("DOMContentLoaded", insertMenu);
