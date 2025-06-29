const searchInput = document.getElementById('meterSearch');

function filterMeters() {
	const filter = searchInput.value.trim().toLowerCase();
	const rows = document.querySelectorAll('table.top tr');

	let currentGroupHeader = null;
	let currentColumnHeader = null;
	let groupHasVisibleRows = false;

	rows.forEach(row => {
		const isGroupHeader = row.querySelector('span.default-group');
		const isColumnHeader = row.querySelector('span.default-bold');

		if (isGroupHeader) {
			if (currentGroupHeader && !groupHasVisibleRows) {
				currentGroupHeader.style.display = 'none';
				if (currentColumnHeader) {
					currentColumnHeader.style.display = 'none';
				}
			}
			currentGroupHeader = row;
			groupHasVisibleRows = false;
			currentGroupHeader.style.display = '';
			currentColumnHeader = null;
			return;
		}

		if (isColumnHeader) {
			currentColumnHeader = row;
			currentColumnHeader.style.display = '';
			return;
		}

		if (filter === '') {
			row.style.display = '';
			groupHasVisibleRows = true;
		} else {
			const text = row.textContent.toLowerCase();
			const match = text.includes(filter);
			row.style.display = match ? '' : 'none';
			if (match) groupHasVisibleRows = true;
		}
	});

	if (currentGroupHeader && !groupHasVisibleRows) {
		currentGroupHeader.style.display = 'none';
		if (currentColumnHeader) {
			currentColumnHeader.style.display = 'none';
		}
	}
}

searchInput.addEventListener('input', filterMeters);
filterMeters();

// Focus input on free typing
document.addEventListener('keydown', function(e) {
	if (!e.ctrlKey && !e.metaKey && !e.altKey && e.key.length === 1 && document.activeElement !== searchInput) {
		searchInput.focus();
	}
});

// Focus input on Ctrl+F or Alt+F
document.addEventListener('keydown', function(e) {
	if (
		searchInput &&
		e.key.toLowerCase() === 'f' &&
		(e.ctrlKey || e.altKey) &&
		!e.metaKey
	) {
		e.preventDefault();
		searchInput.focus();
	}
});
