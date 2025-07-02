// public/js/search_users.js

document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('meterSearch');
	const table = document.querySelector('table');
	const rows = table.querySelectorAll('tr.row');
	const checkbox = document.getElementById('disabledMeters');

	input.addEventListener('input', filterRows);
	if (checkbox) checkbox.addEventListener('change', filterRows);

	function filterRows() {
		const query = input.value.toLowerCase();
		const showDisabled = checkbox && checkbox.checked;

		rows.forEach(row => {
			const text = row.innerText.toLowerCase();
			const isDisabled = row.classList.contains('disabled'); // Add this class if needed

			const matchesSearch = text.includes(query);
			const matchesDisabled = showDisabled || !isDisabled;

			if (matchesSearch && matchesDisabled) {
				row.style.display = '';
			} else {
				row.style.display = 'none';
			}
		});
	}
});
