document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('meterSearch');
	const table = document.querySelector('table');
	const rows = table.querySelectorAll('tr.row');
	let debounceTimeout;
	let refreshTimeout;

	function scheduleRefresh() {
		// Only schedule refresh if input is empty (no filter)
		if (input.value.trim() === '') {
			refreshTimeout = setTimeout(() => {
				location.reload();
			}, 60000); // 60 seconds
		}
	}

	function cancelRefresh() {
		if (refreshTimeout) {
			clearTimeout(refreshTimeout);
		}
	}

	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);
		debounceTimeout = setTimeout(() => {
			filterRows();
			// Cancel refresh if filtering
			if (input.value.trim() !== '') {
				cancelRefresh();
			} else {
				// Schedule refresh again if input cleared
				scheduleRefresh();
			}
		}, 300);
	});

	function filterRows() {
		const query = input.value.toLowerCase();

		rows.forEach(row => {
			const text = row.innerText.toLowerCase();
			const matchesSearch = text.includes(query);

			row.style.display = matchesSearch ? '' : 'none';
		});

		updateRowColors();  // Update row colors after filtering

		// Scroll to top after filtering
		window.scrollTo(0, 0);
	}

	function updateRowColors() {
		const visibleRows = Array.from(rows).filter(row => row.style.display !== 'none');

		visibleRows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
		});
	}

	// Initial setup
	input.focus();
	scheduleRefresh();

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
