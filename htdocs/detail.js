// ===============================
// Constants & Initial Variables
// ===============================

const currentHash = window.location.hash;
const currentRangeMatch = currentHash.match(/#(.+?)\-(.+?)(?:;\d+$)?$/);
const baseUrl = window.location.href.replace(/#.*$/, "");

let dateRange = currentRangeMatch
	? [parseFloat(currentRangeMatch[1]), parseFloat(currentRangeMatch[2])]
	: [Date.now() - 86400000, Date.now()];

let dataSeriesEnabled = (currentHash.match(/;(\d+)$/) || [])[1] || 31;
let lastReloadTime = Date.now();

const colorSets = [['#a9000c', '#011091', '#d7c8dd', '#ad6933', '#00982f'], null];
let g;

const dataUrlCoarse = `data/${meter_serial}/coarse`;
const dataUrlFine = `data/${meter_serial}/fine`;

// ===============================
// Graph Setup & Refresh Handling
// ===============================

fetchAndUpdateGraph(true); // Initial call
setInterval(() => fetchAndUpdateGraph(false), 60000); // Refresh every 60s

/**
 * Fetches CSV data and updates or initializes Dygraph.
 * @param {boolean} isInitialLoad
 */
function fetchAndUpdateGraph(isInitialLoad) {
	// Step 1: Fetch coarse CSV and render it
	fetch(dataUrlCoarse)
		.then(r => r.text())
		.then(coarseCsv => {
			const currentTime = Date.now();

			if (isInitialLoad) {
				g = new Dygraph(
					document.getElementById("div_dygraph"),
					coarseCsv,
					{
						delimiter: ',',
						colors: colorSets[0],
						strokeWidth: 1.5,
						animatedZooms: false,
						showLabelsOnHighlight: true,
						labelsDivStyles: {
							'font-family': 'Verdana, Geneva, sans-serif',
							'text-align': 'left',
							'background': 'none'
						},
						labelsSeparateLines: true,
						labelsDivWidth: 700,
						showRangeSelector: true,
						xAxisHeight: 40,
						interactionModel: Dygraph.defaultInteractionModel,
						dateWindow: dateRange,
						axes: {
							x: {
								valueFormatter: function(x) {
									return formatDate(new Date(x));
								},
								axisLabelFormatter: function(x) {
									const d = new Date(x);
									return d.toLocaleString('da-DA', {
										day: '2-digit',
										month: '2-digit',
										year: 'numeric',
										hour: '2-digit',
										minute: '2-digit'
									}).replace('T', ' ');
								},
								pixelsPerLabel: 80
							}
						},
						maxNumberWidth: 12,
						highlightSeriesOpts: {
							pointSize: 6,
							highlightCircleSize: 6,
							strokeWidth: 2,
							strokeBorderWidth: 1
						},
						unhighlightCallback: updateUrlFromGraph,
						zoomCallback: updateUrlFromGraph,
						clickCallback: updateUrlFromGraph
					}
				);

				g.ready(() => {
					for (let i = 0; i < 5; i++) {
						const checkbox = document.getElementById(i);
						checkbox.checked = ((dataSeriesEnabled >> i) & 1) !== 0;
						g.setVisibility(i, checkbox.checked);
					}
					console.log('Initial range:', g.xAxisRange());
				});
			} else {
				const timeShift = currentTime - lastReloadTime;
				lastReloadTime = currentTime;
				dateRange[0] += timeShift;
				dateRange[1] += timeShift;

				g.updateOptions({
					file: coarseCsv,
					dateWindow: dateRange
				});
			}

			// Step 2: Now fetch fine data and merge
			return fetch(dataUrlFine).then(r => r.text()).then(fineCsv => {
				const mergedCsv = mergeCsv(coarseCsv, fineCsv);
				g.updateOptions({ file: mergedCsv });
				if (!isInitialLoad) {
					updateUrlFromGraph();
					updateLastReadingStats();
				}
				// ✅ Hide spinner after fine data is applied
				const spinner = document.getElementById("graph_spinner");
				if (spinner) spinner.style.display = "none";
			});
		})
		.catch(error => {
			console.error("Error during graph update:", error);
		})
		.finally(() => {
			// ✅ Always hide spinner no matter what
			const spinner = document.getElementById("graph_spinner");
			if (spinner) spinner.style.display = "none";
		});
}

// ===============================
// UI Interaction Handlers
// ===============================

/**
 * Handles checkbox toggling of graph series.
 */
function change(el) {
	const index = parseInt(el.id);
	g.setVisibility(index, el.checked);

	dataSeriesEnabled = el.checked
		? dataSeriesEnabled | (1 << index)
		: dataSeriesEnabled & ~(1 << index);

	updateUrlFromGraph();
}

/**
 * Updates the hash portion of the URL based on graph's current view and settings.
 */
function updateUrlFromGraph() {
	dateRange = g.xAxisRange();

	if (isNaN(dateRange[0]) || isNaN(dateRange[1]) || dateRange[0] >= dateRange[1]) {
		dateRange = [Date.now() - 86400000, Date.now()];
		g.updateOptions({ dateWindow: dateRange });
	}

	const newHash = `#${dateRange[0]}-${dateRange[1]};${dataSeriesEnabled}`;
	window.history.replaceState("", "", `${baseUrl}${newHash}`);
}

/**
 * Fetches and displays the latest energy reading stats.
 */
function updateLastReadingStats() {
	fetch(`last_energy.epl?serial=${meter_serial}`)
		.then(r => r.text())
		.then(text => {
			document.getElementById("last_energy").innerHTML = text;
		});
}

// ===============================
// Helper Functions
// ===============================

/**
 * Merges two CSV strings, removing duplicates and sorting by timestamp.
 */
function mergeCsv(csv1, csv2) {
	const lines1 = csv1.trim().split("\n");
	const lines2 = csv2.trim().split("\n");
	const header = lines1[0];
	const combinedLines = lines1.slice(1).concat(lines2.slice(1));

	const unique = new Map();
	combinedLines.forEach(line => {
		const time = line.split(",")[0];
		unique.set(time, line);
	});

	const sortedLines = Array.from(unique.values()).sort((a, b) =>
		new Date(a.split(",")[0]) - new Date(b.split(",")[0])
	);

	return [header, ...sortedLines].join("\n");
}

/**
 * Formats a JavaScript Date object for Dygraph tooltip.
 */
function formatDate(d) {
	const pad = n => n < 10 ? "0" + n : n;
	const date = `${d.getDate()}.${d.getMonth() + 1}.${d.getFullYear()}`;
	const time = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	return d.getTime() < Date.now() - 86400000 ? `Time: ${date} ${time}` : `Time: ${time}`;
}
