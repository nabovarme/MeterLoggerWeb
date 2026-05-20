let originalTreeData = [];

// =========================
// BODY SCROLL HANDLING
// =========================

//const SCROLL_KEY = 'network_tree_scroll';

//bindScrollPersistence(SCROLL_KEY);
//enableAutoRestore(SCROLL_KEY);

function isOffline(meter) {
	if (!meter || !meter.last_updated) return false;
	const updatedTime = new Date(meter.last_updated * 1000);
	const ageHours = (Date.now() - updatedTime.getTime()) / (1000 * 60 * 60);
	return ageHours >= 1;
}

function createClientNode(client) {
	const meter = client.meter || {};
	const nameText = meter.info || "Client";
	const serial = meter.serial || 'N/A';
	const ssid = meter.ssid || 'N/A';
	const rssi = meter.rssi || 'N/A';
	const swVersion = meter.sw_version || 'N/A';
	const lastUpdated = meter.last_updated;

	let freshnessClass = 'green';
	if (lastUpdated) {
		const updatedTime = new Date(lastUpdated * 1000);
		const ageHours = (Date.now() - updatedTime.getTime()) / (1000 * 60 * 60);
		if (ageHours < 1) freshnessClass = 'green';
		else if (ageHours < 24) freshnessClass = 'yellow';
		else freshnessClass = 'red';
	}

	const htmlContent = `
		<div class="node-title"><a href="/detail_acc.epl?serial=${serial}">${nameText}</a></div>
		<div class="node-serial"><b>serial:</b> ${serial}</div>
		<div class="node-ssid"><b>ssid:</b> ${ssid}</div>
		<div class="node-rssi"><b>rssi:</b> ${rssi}</div>
		<div class="node-version"><b>version:</b> ${swVersion}</div>
	`;

	let children = [];
	if (client.clients && client.clients.length) {
		children = client.clients.map(createClientNode);
	}

	return {
		HTMLclass: `node ${freshnessClass}`,
		innerHTML: htmlContent,
		sortName: nameText,
		children: children
	};
}

function extractNodeTitleText(innerHTML) {
	if (!innerHTML) return null;
	const div = document.createElement('div');
	div.innerHTML = innerHTML;
	const titleDiv = div.querySelector('.node-title');
	return titleDiv ? titleDiv.textContent.trim() : null;
}

function sortTreeNodes(node) {
	if (node.children && node.children.length > 0) {
		node.children.sort((a, b) => {
			const nameA = a.sortName || extractNodeTitleText(a.innerHTML) || "";
			const nameB = b.sortName || extractNodeTitleText(b.innerHTML) || "";
			return nameA.toLowerCase().localeCompare(nameB.toLowerCase());
		});
		node.children.forEach(child => sortTreeNodes(child));
	}
}

function createTreeConfig(routerObj, index) {
	const routerName = routerObj.router?.name || "Router";
	const rootNode = {
		HTMLclass: 'node green root-node',
		innerHTML: `<div class="node-title">${routerName}</div>`,
		children: []
	};

	if (routerObj.clients && routerObj.clients.length) {
		rootNode.children = routerObj.clients.map(createClientNode);
	}

	sortTreeNodes(rootNode);

	return {
		chart: {
			container: `#tree${index}`,
			rootOrientation: 'WEST',
			levelSeparation: 50,
			siblingSeparation: 50,
			subTeeSeparation: 30
		},
		nodeStructure: rootNode
	};
}

async function fetchAndRenderTrees() {
	try {
		const response = await fetch('/api/meters/network_tree');
		if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);

		const data = await response.json();
		originalTreeData = data;

		data.sort((a, b) => {
			const nameA = (a.router?.name || "Router").toLowerCase();
			const nameB = (b.router?.name || "Router").toLowerCase();
			return nameA.localeCompare(nameB);
		});

		// Execute matching immediately without waiting for user typing debounce time
		executeTreeFiltering();
	} catch (err) {
		document.getElementById('tree-canvas').innerText = 'Failed to load tree data: ' + err.message;
		console.error(err);
	}
}

function renderTrees(data) {
	const canvas = document.getElementById('tree-canvas');
	canvas.innerHTML = '';

	data.forEach((routerObj, i) => {
		const treeDiv = document.createElement('div');
		treeDiv.id = `tree${i}`;
		treeDiv.className = 'chart-container';
		canvas.appendChild(treeDiv);
	});

	// Wait for DOM layout to stabilize
	setTimeout(() => {
		data.forEach((routerObj, i) => {
			const config = createTreeConfig(routerObj, i);
			new Treant(config);
		});
	}, 50); // Adjust delay as needed
}

function filterTree(treeData, query, showOnlyOffline = false) {
	const lowerQuery = query.toLowerCase();

	function nodeMatches(meter) {
		const matchesQuery =
			meter?.info?.toLowerCase().includes(lowerQuery) ||
			meter?.serial?.toLowerCase().includes(lowerQuery) ||
			meter?.ssid?.toLowerCase().includes(lowerQuery) ||
			meter?.sw_version?.toLowerCase().includes(lowerQuery);

		const offlineMatch = !showOnlyOffline || isOffline(meter);
		return matchesQuery && offlineMatch;
	}

	function filterClients(clients) {
		const result = [];

		for (const client of clients) {
			const clientMatches = nodeMatches(client.meter);

			if (clientMatches) {
				// Include the full original subtree
				result.push({ ...client });
			} else {
				// Recursively check children
				const filteredChildren = filterClients(client.clients || []);
				if (filteredChildren.length > 0) {
					result.push({ ...client, clients: filteredChildren });
				}
			}
		}

		return result;
	}

	return treeData.map(router => {
		const matchedClients = filterClients(router.clients || []);
		return {
			...router,
			clients: matchedClients
		};
	}).filter(router => router.clients.length > 0);
}

function debounce(fn, delay) {
	let timeout;
	return function (...args) {
		clearTimeout(timeout);
		timeout = setTimeout(() => fn.apply(this, args), delay);
	};
}

//
// =========================
// URL STATE HANDLING (NEW)
// =========================
//

function updateURLState(searchText, offlineOnly) {
	const params = new URLSearchParams(window.location.search);

	if (searchText) {
		params.set('q', searchText);
	} else {
		params.delete('q');
	}

	if (offlineOnly) {
		params.set('offline', '1');
	} else {
		params.delete('offline');
	}

	const newUrl = `${window.location.pathname}?${params.toString()}`;
	history.replaceState(null, '', newUrl);
}

function loadStateFromURL() {
	const params = new URLSearchParams(window.location.search);

	return {
		search: params.get('q') || '',
		offlineOnly: params.get('offline') === '1'
	};
}

function executeTreeFiltering() {
	const query = document.getElementById('networkSearch').value.trim();
	const showOfflineOnly = document.getElementById('offlineMeters').checked;

	// sync URL
	updateURLState(query, showOfflineOnly);

	const shouldFilter = query.length > 0 || showOfflineOnly;
	const filteredData = shouldFilter
		? filterTree(originalTreeData, query, showOfflineOnly)
		: originalTreeData;

	renderTrees(filteredData);
}

const renderFilteredTrees = debounce(executeTreeFiltering, 300);

// =========================
// PAN AND ZOOM HANDLING
// =========================

function initPanZoom() {
	const treesDiv = document.getElementById('trees');
	const treeCanvas = document.getElementById('tree-canvas');
	let scale = 1;
	let pointX = 0;
	let pointY = 0;
	let startX = 0;
	let startY = 0;
	let panning = false;
	
	// Variables for touch pinch-to-zoom
	let initialPinchDistance = null;
	let initialScale = 1;
	let pinchStartX = 0;
	let pinchStartY = 0;

	function setTransform() {
		treeCanvas.style.transform = `translate(${pointX}px, ${pointY}px) scale(${scale})`;
	}

	function getMinScale() {
		const unscaledWidth = treeCanvas.scrollWidth || 1;
		
		// Calculate the scale needed to fit purely based on width
		const fitScale = treesDiv.clientWidth / unscaledWidth;
		
		// Don't force zoom-in if the tree is already thinner than the screen
		return Math.min(fitScale, 1);
	}

	const MAX_SCALE = 4; // Prevent zooming in too far

	// --- MOUSE EVENTS (Desktop) ---
	
	treesDiv.addEventListener('mousedown', (e) => {
		if (e.target.closest('a')) return; 
		e.preventDefault();
		startX = e.clientX - pointX;
		startY = e.clientY - pointY;
		panning = true;
	});

	window.addEventListener('mouseup', () => {
		panning = false;
	});

	window.addEventListener('mousemove', (e) => {
		if (!panning) return;
		e.preventDefault();
		pointX = e.clientX - startX;
		pointY = e.clientY - startY;
		setTransform();
	});

	// --- WHEEL EVENTS (Mouse Wheel & Trackpad) ---
	
	treesDiv.addEventListener('wheel', (e) => {
		e.preventDefault();

		if (e.ctrlKey) {
			// Zoom (Trackpad pinch or Ctrl + Mouse Wheel)
			const xs = (e.clientX - pointX) / scale;
			const ys = (e.clientY - pointY) / scale;

			const delta = -e.deltaY;
			let newScale = delta > 0 ? scale * 1.05 : scale / 1.05;

			// Clamp zoom levels
			const minScale = getMinScale();
			newScale = Math.max(minScale, Math.min(newScale, MAX_SCALE));

			// Only update if scale actually changed (prevents jumping at limits)
			if (newScale !== scale) {
				pointX = e.clientX - xs * newScale;
				pointY = e.clientY - ys * newScale;
				scale = newScale;
			}
		} else {
			// Pan (Two-finger trackpad scroll or regular mouse wheel)
			pointX -= e.deltaX;
			pointY -= e.deltaY;
		}

		setTransform();
	}, { passive: false }); 

	// --- TOUCH EVENTS (Mobile Phones / Tablets) ---
	
	treesDiv.addEventListener('touchstart', (e) => {
		if (e.target.closest('a')) return;
		
		if (e.touches.length === 1) {
			// Single finger: Pan
			startX = e.touches[0].clientX - pointX;
			startY = e.touches[0].clientY - pointY;
			panning = true;
		} else if (e.touches.length === 2) {
			// Two fingers: Pinch
			panning = false;
			initialPinchDistance = Math.hypot(
				e.touches[0].clientX - e.touches[1].clientX,
				e.touches[0].clientY - e.touches[1].clientY
			);
			initialScale = scale;

			// Calculate center of pinch
			const pinchCenterX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
			const pinchCenterY = (e.touches[0].clientY + e.touches[1].clientY) / 2;

			// Store position relative to unscaled canvas
			pinchStartX = (pinchCenterX - pointX) / scale;
			pinchStartY = (pinchCenterY - pointY) / scale;
		}
	}, { passive: false });

	treesDiv.addEventListener('touchmove', (e) => {
		e.preventDefault(); // Prevents native browser zoom and scroll
		
		if (panning && e.touches.length === 1) {
			// Handle Pan
			pointX = e.touches[0].clientX - startX;
			pointY = e.touches[0].clientY - startY;
			setTransform();
		} else if (e.touches.length === 2 && initialPinchDistance) {
			// Handle Pinch Zoom
			const currentDistance = Math.hypot(
				e.touches[0].clientX - e.touches[1].clientX,
				e.touches[0].clientY - e.touches[1].clientY
			);
			
			const distanceRatio = currentDistance / initialPinchDistance;
			let newScale = initialScale * distanceRatio;

			// Clamp zoom levels
			const minScale = getMinScale();
			newScale = Math.max(minScale, Math.min(newScale, MAX_SCALE));
			
			// Update translation to zoom into the pinch center if different from last
			if (newScale !== scale) {
				const currentCenterX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
				const currentCenterY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
				
				pointX = currentCenterX - pinchStartX * newScale;
				pointY = currentCenterY - pinchStartY * newScale;
				scale = newScale;
			}
			
			setTransform();
		}
	}, { passive: false });

	treesDiv.addEventListener('touchend', (e) => {
		panning = false;
		initialPinchDistance = null;
	});
}

// =========================
// INIT
// =========================

window.addEventListener('load', () => {
	const filterInput = document.getElementById('networkSearch');
	const offlineCheckbox = document.getElementById('offlineMeters');

	initPanZoom(); 

	// load from URL
	const urlState = loadStateFromURL();

	filterInput.value = urlState.search;
	offlineCheckbox.checked = urlState.offlineOnly;

	filterInput.focus();

	// Keyboard shortcuts: Ctrl+F or Alt+F to focus search
	document.addEventListener('keydown', (e) => {
		if ((e.ctrlKey || e.altKey) && e.key.toLowerCase() === 'f') {
			e.preventDefault();
			filterInput.focus();
		}
	});

	filterInput.addEventListener('input', renderFilteredTrees);
	offlineCheckbox.addEventListener('change', renderFilteredTrees);

	fetchAndRenderTrees();
});
