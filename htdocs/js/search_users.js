document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('meterSearch');
	const table = document.querySelector('table');
	const rows = table.querySelectorAll('tr.row');
	let debounceTimeout;

	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);
		debounceTimeout = setTimeout(filterRows, 300); // 300ms delay
	});

	function filterRows() {
		const query = input.value.toLowerCase();

		rows.forEach(row => {
			const text = row.innerText.toLowerCase();
			const matchesSearch = text.includes(query);

			row.style.display = matchesSearch ? '' : 'none';
		});

		updateRowColors();  // Update row colors after filtering
	}

	function updateRowColors() {
		// Get only visible rows
		const visibleRows = Array.from(rows).filter(row => row.style.display !== 'none');

		visibleRows.forEach((row, index) => {
			if (index % 2 === 0) {
				row.style.background = '#FFF';  // odd row (0-based)
			} else {
				row.style.background = '#EEE';  // even row (0-based)
			}
		});
	}

	// Focus input on load
	input.focus();

	// Ctrl+F or Alt+F focus shortcut
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
});
