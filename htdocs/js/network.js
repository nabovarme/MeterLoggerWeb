let originalTreeData = [];
let globalMinScale = 1; // Start at 1, and only allow it to decrease to accommodate larger trees

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

	// Use requestAnimationFrame instead of a hardcoded 50ms setTimeout.
	// We nest two of them to ensure the browser has fully completed the paint cycle.
	requestAnimationFrame(() => {
		requestAnimationFrame(() => {
			
			// 1. Initialize all trees
			data.forEach((routerObj, i) => {
				const config = createTreeConfig(routerObj, i);
				new Treant(config);
			});
			
			// 2. Calculate the scale needed for the currently rendered tree
			const treesDiv = document.getElementById('trees');
			const unscaledWidth = canvas.scrollWidth || 1;
			const fitScale = treesDiv.clientWidth / unscaledWidth;
			
			// Only update the global minimum if the new tree requires us 
			// to zoom out further than before.
			globalMinScale = Math.min(globalMinScale, fitScale);
			
			// 3. Trigger the custom event to apply the saved pan/zoom state
			window.dispatchEvent(new Event('treesRendered'));
			
			// 4. FADE IN: Restore opacity
			canvas.style.opacity = '1';
			
		});
	});
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

// =========================
// URL STATE HANDLING
// =========================

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

async function executeTreeFiltering() {
	const query = document.getElementById('networkSearch').value.trim();
	const showOfflineOnly = document.getElementById('offlineMeters').checked;

	// sync URL
	updateURLState(query, showOfflineOnly);

	const shouldFilter = query.length > 0 || showOfflineOnly;
	const filteredData = shouldFilter
		? filterTree(originalTreeData, query, showOfflineOnly)
		: originalTreeData;

	const canvas = document.getElementById('tree-canvas');
	
	// Set transition properties and FADE OUT
	canvas.style.transition = 'opacity 0.2s ease-in-out';
	canvas.style.opacity = '0';

	// Wait 200ms for the fade-out animation to finish before clearing the DOM
	await new Promise(resolve => setTimeout(resolve, 200));

	renderTrees(filteredData);
}

const renderFilteredTrees = debounce(executeTreeFiltering, 300);

// =========================
// PAN AND ZOOM HANDLING
// =========================

function initPanZoom() {
	const treesDiv = document.getElementById('trees');
	const treeCanvas = document.getElementById('tree-canvas');
	
	const STATE_KEY = 'network_tree_panzoom';
	let savedState = { scale: 1, pointX: 0, pointY: 0 };
	
	// Check if the menu explicitly requested a top reset
	if (sessionStorage.getItem('force_scroll_top') === '1') {
		sessionStorage.removeItem('force_scroll_top');
		sessionStorage.removeItem(STATE_KEY);
	} else {
		try {
			const raw = sessionStorage.getItem(STATE_KEY);
			if (raw) savedState = JSON.parse(raw);
		} catch (e) {}
	}

	let scale = savedState.scale;
	let pointX = savedState.pointX;
	let pointY = savedState.pointY;
	
	let panning = false;
	let lastClientX = 0;
	let lastClientY = 0;
	
	// Variables for touch pinch-to-zoom
	let initialPinchDistance = null;
	let initialScale = 1;
	let pinchStartX = 0;
	let pinchStartY = 0;

	// Enforce screen limits so the tree cannot be dragged out of view
	function clampBounds() {
		const viewportWidth = treesDiv.clientWidth;
		const viewportHeight = treesDiv.clientHeight;
		const searchBarHeight = 150; // Approximate height to keep bottom clear of search bar

		const scaledWidth = treeCanvas.scrollWidth * scale;
		const scaledHeight = treeCanvas.scrollHeight * scale;

		// X boundaries
		if (scaledWidth > viewportWidth) {
			pointX = Math.max(viewportWidth - scaledWidth, Math.min(pointX, 0));
		} else {
			// If tree is thinner than window, keep it pinned inside
			pointX = Math.max(0, Math.min(pointX, viewportWidth - scaledWidth));
		}

		// Y boundaries
		const availableHeight = viewportHeight - searchBarHeight;
		if (scaledHeight > availableHeight) {
			pointY = Math.max(availableHeight - scaledHeight, Math.min(pointY, 0));
		} else {
			// If tree is shorter than window, keep it pinned inside
			pointY = Math.max(0, Math.min(pointY, availableHeight - scaledHeight));
		}
	}

	function setTransform() {
		clampBounds();
		treeCanvas.style.transform = `translate(${pointX}px, ${pointY}px) scale(${scale})`;
		
		// Save state every time the view moves
		sessionStorage.setItem(STATE_KEY, JSON.stringify({ scale, pointX, pointY }));
	}

	function getMinScale() {
		// Return the dynamic locked minimum scale value
		return globalMinScale;
	}

	const MAX_SCALE = 4; // Prevent zooming in too far

	// --- MOUSE EVENTS (Desktop) ---

	// Set the default cursor to an open hand for the panning area
	treesDiv.style.cursor = 'grab';

	treesDiv.addEventListener('mousedown', (e) => {
		// If clicking anywhere inside a node, abort panning so the user 
		// can select text, copy serial numbers, or click links naturally.
		if (e.target.closest('.node')) return; 
	
		e.preventDefault();
		lastClientX = e.clientX;
		lastClientY = e.clientY;
		panning = true;
		
		// Change to a closed hand while actively dragging
		treesDiv.style.cursor = 'grabbing';
	});

	window.addEventListener('mouseup', () => {
		panning = false;
	
		// Revert back to the open hand when the mouse button is released
		treesDiv.style.cursor = 'grab';
	});

	window.addEventListener('mousemove', (e) => {
		if (!panning) return;
		e.preventDefault();
		// Add relative delta movement instead of absolute positioning 
		// so it doesn't "stick" if you drag past the boundary
		pointX += e.clientX - lastClientX;
		pointY += e.clientY - lastClientY;
		lastClientX = e.clientX;
		lastClientY = e.clientY;
		setTransform();
	});

	// --- WHEEL EVENTS (Mouse Wheel & Trackpad) ---
	
	treesDiv.addEventListener('wheel', (e) => {
		e.preventDefault();

		if (e.ctrlKey) {
			// Find current point relative to unscaled canvas before zoom
			const xs = (e.clientX - pointX) / scale;
			const ys = (e.clientY - pointY) / scale;

			// Logarithmic transform via velocity delta ensures fluid transitions. Zoom speed multiplier set to 0.008
			const zoomFactor = 0.008; 
			let newScale = scale * Math.exp(-e.deltaY * zoomFactor);

			// Clamp zoom levels safely
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
			lastClientX = e.touches[0].clientX;
			lastClientY = e.touches[0].clientY;
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
			// Handle Pan (Delta based)
			pointX += e.touches[0].clientX - lastClientX;
			pointY += e.touches[0].clientY - lastClientY;
			lastClientX = e.touches[0].clientX;
			lastClientY = e.touches[0].clientY;
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
				setTransform();
			}
		}
	}, { passive: false });

	treesDiv.addEventListener('touchend', (e) => {
		panning = false;
		initialPinchDistance = null;
	});

	// Apply transform when initial trees finish rendering
	window.addEventListener('treesRendered', () => {
		setTransform();
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
