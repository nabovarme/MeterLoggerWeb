let allMetersData = []; // global, preserved
let currentLinkIndex = -1; // index for keyboard navigation

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('meterSearch');
	const disabledCheckbox = document.getElementById('disabledMeters');
	const container = document.getElementById('meterContainer');

	// IMPORTANT: body is the real scroll container in your layout
	const scrollEl = document.body;

	let isInitialLoad = true;

	// Helper: Check if meter is active
	const isActiveMeter = meter => meter.enabled > 0;

	// Helper: Check if meter matches search text
	const matchesSearch = (meter, searchText) => {
		const textToCheck = [
			meter.info,
			meter.serial
		].map(s => (s || '').toLowerCase()).join(' ');
		return searchText === '' || textToCheck.includes(searchText);
	};

	// =========================
	// URL STATE HANDLING
	// =========================

	function updateURLState(searchText, disabledOnly) {
		const params = new URLSearchParams(window.location.search);

		if (searchText) {
			params.set('q', searchText);
		} else {
			params.delete('q');
		}

		if (disabledOnly) {
			params.set('disabled', '1');
		} else {
			params.delete('disabled');
		}

		const newUrl = `${window.location.pathname}?${params.toString()}`;

		history.replaceState(
			{},
			'',
			newUrl
		);
	}

	function loadStateFromURL() {
		const params = new URLSearchParams(window.location.search);

		return {
			search: params.get('q') || '',
			disabledOnly: params.get('disabled') === '1'
		};
	}

	// =========================
	// SCROLLING
	// =========================

	function saveScroll() {
		if (filterInput.value || disabledCheckbox.checked) {
			sessionStorage.setItem('meters_scroll', scrollEl.scrollTop);
		}
	}

	function restoreScroll() {
		const y = Number(sessionStorage.getItem('meters_scroll') || 0);

		requestAnimationFrame(() => {
			scrollEl.scrollTop = y;
		});
	}

	// Listen on REAL scroll container
	scrollEl.addEventListener('scroll', saveScroll, { passive: true });

	// Fetch meters from API
	async function fetchMeters() {
		try {
			const response = await fetch('/api/meters');
			if (!response.ok) throw new Error(`API error: ${response.status}`);
			const data = await response.json();
			allMetersData = data;
			return data;
		} catch (error) {
			showError(`Failed to load meters: ${error.message}`);
			return [];
		}
	}

	// Show error message in container
	function showError(message) {
		container.innerHTML = `<p class="error">${message}</p>`;
	}

	// Render meters to container
	function renderMeters(data) {
		container.innerHTML = '';

		data.forEach(group => {
			const groupDiv = document.createElement('div');
			groupDiv.className = 'meter-group';
			groupDiv.textContent = group.group_name;
			container.appendChild(groupDiv);

			const tableWrapper = document.createElement('div');
			tableWrapper.className = 'meter-table-wrapper';

			// Add column headers once per group
			const columnsDiv = document.createElement('div');
			columnsDiv.className = 'meter-columns';
			columnsDiv.innerHTML = `
				<div>Serial</div>
				<div>Info</div>
				<div style="white-space: nowrap;">Energy <div class="meter-columns-unit">kWh</div></div>
				<div style="white-space: nowrap;">Volume <div class="meter-columns-unit">m<sup>3</sup></div></div>
				<div>Hours</div>
				<div style="white-space: nowrap;">Remaining <div class="meter-columns-unit">kWh</div></div>
				<div>Time left</div>
			`;
			tableWrapper.appendChild(columnsDiv);

			// Sort meters by info (optional)
			const sortedMeters = [...group.meters].sort((a, b) =>
				(a.info || '').localeCompare(b.info || '')
			);

			// Add each meter row
			sortedMeters.forEach(meter => {
				const rowDiv = document.createElement('div');
				rowDiv.className = 'meter-row';

				if (meter.enabled === 0) {
					rowDiv.classList.add('meter-disabled');
				}

				rowDiv.innerHTML = `
					<div><a href="detail_acc.epl?serial=${encodeURIComponent(meter.serial || '')}">${meter.serial || ''}</a></div>
					<div>${meter.info || ''}</div>
					<div>${meter.energy || 0}</div>
					<div>${meter.volume || 0}</div>
					<div>${meter.hours || 0}</div>
					<div>${meter.kwh_remaining || 0}</div>
					<div>${meter.time_remaining_hours_string || ''}</div>
				`;

				tableWrapper.appendChild(rowDiv);
			});

			container.appendChild(tableWrapper);
		});
	}

	// Filter meters and re-render
	function filterMeters(resetScroll = true) {
		const searchText = filterInput.value.toLowerCase();
		const disabledOnly = disabledCheckbox.checked;

		// sync URL state
		updateURLState(searchText, disabledOnly);

		const filteredData = allMetersData.map(group => {
			const groupMatches = group.group_name.toLowerCase().includes(searchText);

			let filteredMeters;

			if (groupMatches) {
				filteredMeters = group.meters.filter(meter =>
					(disabledOnly ? meter.enabled === 0 : true)
				);
			} else {
				filteredMeters = group.meters.filter(meter =>
					matchesSearch(meter, searchText) &&
					(disabledOnly ? meter.enabled === 0 : true)
				);
			}

			return { group_name: group.group_name, meters: filteredMeters };
		}).filter(group => group.meters.length > 0);

		renderMeters(filteredData);

		// Always scroll to top on ANY filter change (except initial load restore)
		if (!isInitialLoad) {
			sessionStorage.removeItem('meters_scroll');
			scrollEl.scrollTop = 0;
		}

		requestAnimationFrame(() => {
			if (isInitialLoad) {
				restoreScroll();
				isInitialLoad = false;
			}
		});

		// Reset keyboard navigation efter filter
		currentLinkIndex = -1;
	}

	// Debounce utility
	function debounce(fn, delay = 300) {
		let timeoutId;
		return (...args) => {
			clearTimeout(timeoutId);
			timeoutId = setTimeout(() => fn(...args), delay);
		};
	}

	// Keyboard navigation using Arrow Up / Arrow Down
	function getVisibleSerialLinks() {
		return Array.from(document.querySelectorAll('.meter-row a'))
			.filter(link => link.offsetParent !== null);
	}

	document.addEventListener('keydown', (e) => {
		const menuEl = document.getElementById('menu');

		// If the menu is open, don't navigate meters
		if (menuEl && menuEl.classList.contains('show')) return;

		const links = getVisibleSerialLinks();
		if (!links.length) return;

		if (e.key === 'ArrowDown') {
			e.preventDefault();
			currentLinkIndex = (currentLinkIndex + 1) % links.length;
			links[currentLinkIndex].focus();
		} else if (e.key === 'ArrowUp') {
			e.preventDefault();
			currentLinkIndex = (currentLinkIndex - 1 + links.length) % links.length;
			links[currentLinkIndex].focus();
		}
	});

	// Initialize app
	async function init() {
		await fetchMeters();

		// load state from URL
		const urlState = loadStateFromURL();

		filterInput.value = urlState.search;
		disabledCheckbox.checked = urlState.disabledOnly;

		renderMeters(allMetersData);

		filterMeters(false);

		filterInput.addEventListener('input', debounce(() => filterMeters(false)));
		disabledCheckbox.addEventListener('change', () => filterMeters(false));

		// Focus search input on page load
		filterInput.focus();

		// Keyboard shortcuts: Ctrl+F or Alt+F to focus search
		document.addEventListener('keydown', (e) => {
			if ((e.ctrlKey || e.altKey) && e.key.toLowerCase() === 'f') {
				e.preventDefault();
				filterInput.focus();
			}
		});
	}

	init();

	window.addEventListener('beforeunload', () => {
		sessionStorage.setItem('meters_scroll', scrollEl.scrollTop);
	});
});
