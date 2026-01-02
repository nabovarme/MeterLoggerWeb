document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('wifiPendingSearch');
	const table = document.getElementById('wifi_table');
	const rows = () => table.querySelectorAll('tbody tr'); // dynamic rows
	let debounceTimeout;
	let refreshTimeout;

	// --- Refresh logic ---
	function scheduleRefresh() {
		refreshTimeout = setTimeout(async () => {
			const query = input.value.toLowerCase();

			// Reload table data dynamically
			if (typeof loadWifi === 'function') {
				await loadWifi(); // assumes loadWifi() reloads table tbody
			}

			// Re-apply current filter after reload
			filterRows(query);

			// Schedule next refresh
			scheduleRefresh();
		}, 60000); // 60 seconds
	}

	function cancelRefresh() {
		if (refreshTimeout) {
			clearTimeout(refreshTimeout);
			refreshTimeout = null;
		}
	}

	// --- Filtering ---
	function filterRows(query = input.value.toLowerCase()) {
		rows().forEach(row => {
			const text = row.innerText.toLowerCase();
			const matchesSearch = text.includes(query);
			row.style.display = matchesSearch ? '' : 'none';
		});

		updateRowColors();
		window.scrollTo(0, 0);
	}

	function updateRowColors() {
		const visibleRows = Array.from(rows()).filter(row => row.style.display !== 'none');
		visibleRows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
		});
	}

	// --- Debounced input handler ---
	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);
		debounceTimeout = setTimeout(() => {
			filterRows();
			// Refresh continues automatically even while typing
		}, 300);
	});

	// --- Ctrl+F / Alt+F shortcut to focus search ---
	document.addEventListener('keydown', (e) => {
		if (
			e.key.toLowerCase() === 'f' &&
			(e.ctrlKey || e.altKey) &&
			!e.metaKey
		) {
			e.preventDefault();
			input.focus();
		}
	});

	// --- Initial setup ---
	input.focus();
	scheduleRefresh();
});
