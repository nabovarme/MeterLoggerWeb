document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('wifiPendingSearch');
	const table = document.getElementById('wifi_table');

	const rows = () => table.querySelectorAll('tbody tr');

	let debounceTimeout;
	let refreshTimeout;

	function filterRows(query = input.value.toLowerCase()) {
		rows().forEach(row => {
			const text = row.innerText.toLowerCase();
			row.style.display = text.includes(query) ? '' : 'none';
		});

		updateRowColors();

		// ❌ removed: window.scrollTo(0, 0);
	}

	function updateRowColors() {
		const visibleRows = Array.from(rows()).filter(r => r.style.display !== 'none');

		visibleRows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
		});
	}

	function scheduleRefresh() {
		refreshTimeout = setTimeout(async () => {
			const query = input.value.toLowerCase();

			if (typeof loadWifi === 'function') {
				await loadWifi();
			}

			filterRows(query);

			scheduleRefresh();
		}, 60000);
	}

	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);

		debounceTimeout = setTimeout(() => {
			filterRows();
		}, 300);
	});

	document.addEventListener('keydown', (e) => {
		if (e.key.toLowerCase() === 'f' && (e.ctrlKey || e.altKey) && !e.metaKey) {
			e.preventDefault();
			input.focus();
		}
	});

	input.focus();
	scheduleRefresh();
});
