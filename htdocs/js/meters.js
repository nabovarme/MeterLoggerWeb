let allMetersData = []; // global, preserved

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('meterSearch');
	const disabledCheckbox = document.getElementById('disabledMeters');
	const container = document.getElementById('meterContainer');

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
				<div>Time remaining</div>
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

				if (!isActiveMeter(meter)) {
					rowDiv.classList.add('meter-disabled');
				}
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
	function filterMeters() {
		const searchText = filterInput.value.toLowerCase();
		const disabledOnly = disabledCheckbox.checked;

		const filteredData = allMetersData.map(group => {
			const groupMatches = group.group_name.toLowerCase().includes(searchText);

			let filteredMeters;

			if (groupMatches) {
				filteredMeters = group.meters.filter(meter =>
					(disabledOnly ? !isActiveMeter(meter) : true)
				);
			} else {
				filteredMeters = group.meters.filter(meter =>
					matchesSearch(meter, searchText) &&
					(disabledOnly ? !isActiveMeter(meter) : true)
				);
			}

			return { group_name: group.group_name, meters: filteredMeters };
		}).filter(group => group.meters.length > 0);

		renderMeters(filteredData);
		container.scrollTop = 0;
	}

	// Debounce utility
	function debounce(fn, delay = 300) {
		let timeoutId;
		return (...args) => {
			clearTimeout(timeoutId);
			timeoutId = setTimeout(() => fn(...args), delay);
		};
	}

	// Initialize app
	async function init() {
		await fetchMeters();
		renderMeters(allMetersData);

		filterInput.addEventListener('input', debounce(filterMeters));
		disabledCheckbox.addEventListener('change', filterMeters);

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
});
