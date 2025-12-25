document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('wifiPendingSearch');
	const table = document.getElementById('wifi_table');
	const rows = () => table.querySelectorAll('tbody tr');
	let debounceTimeout;
	let refreshTimeout;

	function scheduleRefresh() {
		if (input.value.trim() === '') {
			refreshTimeout = setTimeout(() => {
				location.reload();
			}, 60000);
		}
	}

	function cancelRefresh() {
		if (refreshTimeout) {
			clearTimeout(refreshTimeout);
			refreshTimeout = null;
		}
	}

	function filterRows() {
		const query = input.value.toLowerCase();

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

	input.addEventListener('input', () => {
		clearTimeout(debounceTimeout);
		debounceTimeout = setTimeout(() => {
			filterRows();
			if (input.value.trim() !== '') {
				cancelRefresh();
			} else {
				scheduleRefresh();
			}
		}, 300);
	});

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

	input.focus();
	scheduleRefresh();
});
