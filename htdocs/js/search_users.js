document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('meterSearch');
	const table = document.querySelector('table');
	const rows = table.querySelectorAll('tr.row');

	input.addEventListener('input', filterRows);

	function filterRows() {
		const query = input.value.toLowerCase();

		rows.forEach(row => {
			const text = row.innerText.toLowerCase();
			const matchesSearch = text.includes(query);

			if (matchesSearch) {
				row.style.display = '';
			} else {
				row.style.display = 'none';
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
