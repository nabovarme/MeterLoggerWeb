// menu.js

// List of menu items and separators for the floating menu
const menuItems = [
	{ text: "Meters", href: "/index.html" },
	{ text: "Map", href: "/map" },
	{ text: "Network", href: "/network" },
	{ text: "Valve control", href: "/valve_control.epl" },
	{ text: "User log", href: "/users.epl" },
	{ text: "Payments pending", href: "/payments_pending.epl" },
	{ text: "Alarms", href: "/alarms.html" },
	{ separator: true },
	{ text: "Logout", href: "/logout" }
];

// Create and insert the burger icon and floating menu into the page
function insertMenu() {
	const burger = document.createElement("div");
	burger.className = "burger";

	// Hamburger icon text
	burger.innerText = "☰";

	// Toggle menu visibility on burger click
	burger.onclick = toggleMenu;

	const menu = document.createElement("nav");
	menu.id = "menu";
	menu.className = "floating-menu";

	// Build menu links and separators dynamically
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
			a.innerText = item.text;

			// Hide the menu shortly after clicking a link
			a.addEventListener("click", function () {
				setTimeout(() => {
					menu.classList.remove("show");
				}, 150); // 150ms delay — tweak if needed
			});

			menu.appendChild(a);
		}
	});

	// Append burger and menu to the document body
	document.body.appendChild(burger);
	document.body.appendChild(menu);

	// Close the menu when clicking outside the menu or burger icon
	document.addEventListener("click", function (e) {
		const menuEl = document.getElementById("menu");
		const isClickInsideMenu = menuEl.contains(e.target);
		const isClickOnBurger = burger.contains(e.target);

		// Remove menu show class if click is outside menu and burger
		if (!isClickInsideMenu && !isClickOnBurger) {
			menuEl.classList.remove("show");
		}
	});
}

// Toggle menu visibility on burger icon click
function toggleMenu() {
	const menuEl = document.getElementById("menu");
	if (menuEl) {
		menuEl.classList.toggle("show");
	}
}

// Initialize menu once DOM content is fully loaded
document.addEventListener("DOMContentLoaded", insertMenu);
