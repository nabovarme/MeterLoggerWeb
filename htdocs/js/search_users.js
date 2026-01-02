document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('meterSearch');
	const table = document.querySelector('table');
	const rows = table.querySelectorAll('tr.row');
	let debounceTimeout;
	let refreshTimeout;

	// --- Refresh logic ---
	function scheduleRefresh() {
		// Only schedule if input is empty AND not focused
		if (input.value.trim() === '' && document.activeElement !== input) {
			refreshTimeout = setTimeout(() => {
				location.reload();
			}, 60000); // 60 seconds
		}
	}

	function cancelRefresh() {
		if (refreshTimeout) {
			clearTimeout(refreshTimeout);
			refreshTimeout = null;
		}
	}

	// Pause refresh while typing/focused
	input.addEventListener('focus', cancelRefresh);
	input.addEventListener('blur', scheduleRefresh);

	// --- Filtering ---
	function filterRows() {
		const query = input.value.toLowerCase();

		rows.forEach(row => {
			const text = row.innerText.toLowerCase();
			const matchesSearch = text.includes(query);
			row.style.display = matchesSearch ? '' : 'none';
		});

		updateRowColors();
		window.scrollTo(0, 0);
	}

	function updateRowColors() {
		const visibleRows = Array.from(rows).filter(row => row.style.display !== 'none');
		visibleRows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
		});
	}

	// --- Debounced input handler ---
	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);
		debounceTimeout = setTimeout(() => {
			filterRows();

			if (input.value.trim() !== '') {
				cancelRefresh(); // stop refresh while searching
			} else {
				scheduleRefresh(); // resume if empty
			}
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
