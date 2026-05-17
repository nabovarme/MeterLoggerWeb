// url_state.js

// Get query parameter
function getQueryParam(key) {
	return new URLSearchParams(window.location.search).get(key) || '';
}

// Set / update query parameter
function setQueryParam(key, value) {
	const params = new URLSearchParams(window.location.search);

	if (value) params.set(key, value);
	else params.delete(key);

	const newUrl = `${window.location.pathname}?${params.toString()}`;
	history.replaceState({}, '', newUrl);
}
