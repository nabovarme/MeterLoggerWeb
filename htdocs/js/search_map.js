// Remove default search control input box but keep control active
document.querySelector('.leaflet-control-search').style.display = 'none';

const searchInput = document.getElementById('meterSearch');

searchInput.addEventListener('input', function () {
	const val = this.value;
	
	if (val.length < 1) {
		// Clear search if empty
		controlSearch.cancel();
	} else {
		// Trigger Leaflet.Search programmatic search
		controlSearch.searchText = val;
		controlSearch._start(val);
	}
});

// Optional: clear input when search popup closes
controlSearch.on('search:collapsed', function () {
	searchInput.value = '';
});
