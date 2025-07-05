let originalTreeData = [];

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
		<div class="node-title">${nameText}</div>
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
			const nameA = (a.text?.name) || extractNodeTitleText(a.innerHTML) || "";
			const nameB = (b.text?.name) || extractNodeTitleText(b.innerHTML) || "";
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
		const response = await fetch('/api/meters/tree');
		if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);

		const data = await response.json();
		originalTreeData = data;

		data.sort((a, b) => {
			const nameA = (a.router?.name || "Router").toLowerCase();
			const nameB = (b.router?.name || "Router").toLowerCase();
			return nameA.localeCompare(nameB);
		});

		renderTrees(data);
	} catch (err) {
		document.getElementById('trees').innerText = 'Failed to load tree data: ' + err.message;
		console.error(err);
	}
}

function renderTrees(data) {
	const container = document.getElementById('trees');
	container.innerHTML = '';

	data.forEach((routerObj, i) => {
		const treeDiv = document.createElement('div');
		treeDiv.id = `tree${i}`;
		treeDiv.className = 'chart-container';
		container.appendChild(treeDiv);

		const config = createTreeConfig(routerObj, i);
		new Treant(config);
	});
}

function filterTree(treeData, query, showOnlyOffline = false) {
	const lowerQuery = query.toLowerCase();

	function nodeMatches(meter) {
		const matchesQuery = meter?.info?.toLowerCase().includes(lowerQuery)
			|| meter?.serial?.toLowerCase().includes(lowerQuery)
			|| meter?.ssid?.toLowerCase().includes(lowerQuery);
		const offlineMatch = !showOnlyOffline || isOffline(meter);
		return matchesQuery && offlineMatch;
	}

	function filterClients(clients) {
		const result = [];

		for (const client of clients) {
			const children = filterClients(client.clients || []);
			const clientMatches = nodeMatches(client.meter);

			if (clientMatches || children.length > 0) {
				result.push({ ...client, clients: children });
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

const renderFilteredTrees = debounce(function () {
	const query = document.getElementById('networkSearch').value.trim();
	const showOfflineOnly = document.getElementById('offlineMeters').checked;

	const shouldFilter = query.length > 0 || showOfflineOnly;
	const filteredData = shouldFilter
		? filterTree(originalTreeData, query, showOfflineOnly)
		: originalTreeData;

	renderTrees(filteredData);
	window.scrollTo({ top: 0, behavior: 'smooth' });
}, 300);

document.getElementById('networkSearch').addEventListener('input', renderFilteredTrees);
document.getElementById('offlineMeters').addEventListener('change', renderFilteredTrees);

window.addEventListener('load', () => {
	document.getElementById('networkSearch').focus();
});

fetchAndRenderTrees();
