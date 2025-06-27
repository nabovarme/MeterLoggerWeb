// menu.js

const menuItems = [
	{ text: "Overview", href: "/index.epl" },
	{ text: "Map", href: "/map" },
	{ text: "Network", href: "/network" },
	{ text: "Valve control", href: "/valve_control.epl" },
	{ text: "User log", href: "/users.epl" },
	{ text: "Payments pending", href: "/payments_pending.epl" },
	{ text: "Alarms", href: "/alarms.epl" },
	{ separator: true },
	{ text: "Logout", href: "/logout" }
];

// Create and insert menu HTML
function insertMenu() {
	const burger = document.createElement("div");
	burger.className = "burger";
	burger.innerText = "☰";
	burger.onclick = toggleMenu;

	const menu = document.createElement("nav");
	menu.id = "menu";
	menu.className = "floating-menu";

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
			menu.appendChild(a);
		}
	});

	document.body.appendChild(burger);
	document.body.appendChild(menu);
}

// Toggle menu visibility
function toggleMenu() {
	document.getElementById("menu")?.classList.toggle("show");
}

// Call insertMenu once DOM is ready
document.addEventListener("DOMContentLoaded", insertMenu);
