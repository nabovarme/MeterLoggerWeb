/*
 * Energy Detail Dashboard Script
 *
 * This script powers the interactive energy usage detail view. It performs the following functions:
 *
 * - Initializes a Dygraph instance using coarse data from the backend.
 * - Loads and merges higher-resolution (fine) CSV data into the graph.
 * - Fetches account data (e.g. last energy reading, volume, remaining kWh) from the API and updates the UI.
 * - Displays time-aligned annotations (e.g. payments, memberships) on the graph.
 * - Enables hover and click behavior on annotations to highlight and scroll to corresponding payment rows.
 * - Calculates and displays consumption statistics (total kWh and average kW/h) for the currently selected graph range.
 * - Dynamically renders a payment history table and filters it based on the visible time window in the graph.
 * - Refreshes account data and nudges the graph forward every 60 seconds to stay up-to-date in real time.

                   ┌────────────────────────────────────┐
                   │ Start                              │
                   │ fetchAndUpdateGraph()              │
                   └────────────┬───────────────────────┘
                                │
                                ▼
                ┌────────────────────────────────────┐
                │ Fetch Coarse CSV                   │
                │ fetch(dataUrlCoarse)               │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────┐
                │ Convert CSV timestamps             │
                │ convertCsvSecondsToMs()            │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────┐
                │ Init or Update Dygraph             │
                │ new Dygraph(...)                   │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────┐
                │ Fetch Account Info                 │
                │ fetch(accountUrl)                  │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────────────┐
                │ Update UI Stats                            │
                │ updateRemainingKwhInfo(),                  │
                │ updateLastReadingStats()                   │
                └────────────┬───────────────────────────────┘
                             ▼
                ┌────────────────────────────────────────────┐
                │ Create & Set Graph Annotations             │
                │ graph.setAnnotations(),                    │
                │ snapToNearestTimestamp()                   │
                └────────────┬───────────────────────────────┘
                             ▼
                ┌────────────────────────────────────────────┐
                │ Bind Annotation Events                     │
                │ bindAnnotationEventsAndIds(),              │
                │ handleAnnotationClick(), etc.              │
                └────────────┬───────────────────────────────┘
                             ▼
                ┌────────────────────────────────────┐
                │ Fetch Fine CSV                     │
                │ fetch(dataUrlFine)                 │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────┐
                │ Merge Coarse + Fine CSV            │
                │ mergeCsv()                         │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────┐
                │ Update Dygraph with Merged Data    │
                │ g.updateOptions()                  │
                └────────────┬───────────────────────┘
                             ▼
                ┌────────────────────────────────────────────┐
                │ Calculate Consumption for Range            │
                │ updateConsumptionFromGraphRange()          │
                └────────────┬───────────────────────────────┘
                             ▼
                ┌────────────────────────────────────────────┐
                │ Filter Payment Table by Graph Range        │
                │ filterPaymentsBySelectedGraphRange()       │
                └────────────┬───────────────────────────────┘
                             ▼
                ┌────────────────────────────────────────────┐
                │ Repeat Every 60 Seconds                    │
                │ setInterval(fetchAndUpdateGraph, 60000)    │
                └────────────────────────────────────────────┘
 */

// Colors for graph
var colorSets = [['#999999'], null];

// Graph instance
var g;

// Data and account API URLs
var dataUrlCoarse = '/api/data_acc/' + meter_serial + '/coarse';
var dataUrlFine = '/api/data_acc/' + meter_serial + '/fine';
var accountUrl = '/api/account/' + meter_serial;

// ✅ Cache for full account data JSON
var accountData = null;

/*----------------
 * Helper functions
 *---------------*/

// Helper to convert CSV timestamps from seconds to milliseconds (Dygraph expects ms)
function convertCsvSecondsToMs(csv) {
	const lines = csv.trim().split("\n");
	const header = lines[0];
	const convertedLines = lines.slice(1).map(line => {
		const parts = line.split(",");
		parts[0] = (parseInt(parts[0], 10) * 1000).toString();
		return parts.join(",");
	});
	return [header, ...convertedLines].join("\n");
}

// Normalize amount to 2 decimal places (for consistent display)
function normalizeAmount(amount) {
	return parseFloat(amount).toFixed(2);
}

// Formats timestamps for display in labels
function formatDate(d) {
	const pad = (n) => (n < 10 ? '0' + n : n);
	const now = new Date();
	if (d.getTime() < now.getTime() - (1000 * 86400)) {
		// If older than 1 day, show full date + time
		return `Time: ${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	} else {
		// Otherwise, show only time
		return `Time: ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	}
}

// Merges two CSV strings by timestamp, keeping unique and sorted entries
function mergeCsv(csv1, csv2) {
	const lines1 = csv1.trim().split("\n");
	const lines2 = csv2.trim().split("\n");

	const header = lines1[0];
	const allLines = lines1.slice(1).concat(lines2.slice(1));

	const uniqueRows = new Map();
	for (const line of allLines) {
		const timestamp = line.split(",")[0];
		uniqueRows.set(timestamp, line);
	}

	const sortedRows = Array.from(uniqueRows.values()).sort((a, b) => {
		return parseInt(a.split(",")[0], 10) - parseInt(b.split(",")[0], 10);
	});

	return [header].concat(sortedRows).join("\n");
}

/*----------------------
 * UI update functions
 *---------------------*/

// Updates the stats based on selected time range in graph
function updateConsumptionFromGraphRange() {
	if (!g || !g.rawData_) return;

	const range = g.xAxisRange();
	let minY = null, maxY = null;

	// Find minY at start of range
	for (let i = 0; i < g.rawData_.length; i++) {
		const ts = g.rawData_[i][0];
		const val = parseFloat(g.rawData_[i][1]);
		if (ts >= range[0]) {
			minY = val;
			break;
		}
	}

	// Find maxY at end of range
	for (let i = g.rawData_.length - 1; i >= 0; i--) {
		const ts = g.rawData_[i][0];
		const val = parseFloat(g.rawData_[i][1]);
		if (ts <= range[1]) {
			maxY = val;
			break;
		}
	}

	if (minY == null || maxY == null) return;

	const consumption = (maxY - minY);
	const avg = consumption / ((range[1] - range[0]) / (1000 * 3600));

	document.getElementById('consumption_in_range').innerHTML =
		'<span class="default-bold">Consumption for selected period </span>' +
		'<span class="default">' +
		consumption.toFixed(0) + ' kWh, at ' + avg.toFixed(2) + ' kW/h</span>';

	// 👇 Filter payments table
	filterPaymentsBySelectedGraphRange(g);
}

function updateLastReadingStats() {
	document.getElementById("last_energy").innerHTML =
		normalizeAmount(accountData.last_energy) + " kWh<br> " +
		normalizeAmount(accountData.last_volume) + " m<sup>3</sup><br>" +
		normalizeAmount(accountData.last_hours) + " hours<br>";
}

function updateRemainingKwhInfo() {
	if (accountData && accountData.kwh_remaining != null) {
		// Round kwh_remaining to the nearest integer
		const kwhRemainingInt = Math.round(accountData.kwh_remaining);

		document.getElementById("kwh_remaining").innerHTML =
			normalizeAmount(kwhRemainingInt) + " kWh remaining, " +
			accountData.time_remaining_hours_string + " at " +
			accountData.avg_energy_last_day + " kW/h";
	}
}

// Renders the payment rows in the table
function renderPaymentRowsFromAccountData(payments) {
	const container = document.getElementById("payments_table");
	container.innerHTML = '';

	if (!payments.length) {
		container.innerHTML = '<div class="payment-row empty">No payments data available</div>';
		return;
	}

	const header = document.createElement('div');
	header.className = 'payment-row payment-header';
	header.innerHTML = `
		<div>Date</div>
		<div>Info</div>
		<div>Amount</div>
		<div>Price</div>
	`;
	container.appendChild(header);

	payments.forEach(d => {
		const row = document.createElement('div');
		row.className = 'payment-row';
		row.id = `payment-${d.id}`;
		row.setAttribute('data-payment-time', d.payment_time);

		const kWh = (d.type === 'payment' && d.price) ? Math.round(d.amount / d.price) + ' kWh' : '';
		const amountStr = normalizeAmount(d.amount || 0) + ' kr';
		const priceStr = (d.type === 'payment' && d.price) ? normalizeAmount(d.price || 0) + ' kr/kWh' : '';
		const dateStr = new Date(d.payment_time * 1000).toLocaleString('da-DA').replace('T', ' ');

		row.innerHTML = `
			<div>${dateStr}</div>
			<div>${kWh} ${d.info || ''}</div>
			<div>${amountStr}</div>
			<div>${priceStr}</div>
		`;

		container.appendChild(row);
	});
}

/*-----------------------
 * Annotation functions
 *----------------------*/

function handleAnnotationHoverIn(e) {
	const el = e.currentTarget;
	const annotationId = el.dataset.annotationId;
	if (!annotationId) return;
	const row = document.getElementById(annotationId);
	if (row) row.classList.add('highlight');
	const title = el.getAttribute('title') || '';
	const lines = title.split('\n');
	if (lines.length > 1) {
		el.setAttribute('data-original-title', title);
		el.setAttribute('title', lines.slice(1).join('\n'));
	}
}

function handleAnnotationHoverOut(e) {
	const el = e.currentTarget;
	const annotationId = el.dataset.annotationId;
	if (!annotationId) return;
	const row = document.getElementById(annotationId);
	if (row) row.classList.remove('highlight');
	const original = el.getAttribute('data-original-title');
	if (original) {
		el.setAttribute('title', original);
		el.removeAttribute('data-original-title');
	}
}

function handleAnnotationClick(e) {
	const el = e.currentTarget;
	const annotationId = el.dataset.annotationId;
	if (!annotationId) return;
	const row = document.getElementById(annotationId);
	if (row) {
		row.scrollIntoView({ behavior: 'smooth', block: 'center' });
		row.classList.add('highlight-clicked');
		setTimeout(() => row.classList.remove('highlight-clicked'), 2000);
	}
}

function initAnnotationHoverListeners() {
	const annotations = document.querySelectorAll('.dygraph-annotation');
	annotations.forEach(el => {
		el.removeEventListener('mouseenter', handleAnnotationHoverIn);
		el.removeEventListener('mouseleave', handleAnnotationHoverOut);
		el.removeEventListener('click', handleAnnotationClick);
		el.addEventListener('mouseenter', handleAnnotationHoverIn);
		el.addEventListener('mouseleave', handleAnnotationHoverOut);
		el.addEventListener('click', handleAnnotationClick);
	});
}

// Binds DOM elements to corresponding payment rows via annotation IDs
function bindAnnotationEventsAndIds(graph) {
	setTimeout(() => {
		if (!graph || !graph.annotations_) return;
		const annotations = document.querySelectorAll('.dygraph-annotation');
		annotations.forEach(el => {
			const title = el.getAttribute('title');
			const lines = title.split("\n");
			const idLine = lines[0];
			if (!idLine.startsWith("#")) return;
			const rawId = idLine.substring(1);
			const annotationId = `payment-${rawId}`;
			el.dataset.annotationId = annotationId;
		});
		initAnnotationHoverListeners();
	}, 0);
}

function filterPaymentsBySelectedGraphRange(graph) {
	const [start, end] = graph.xAxisRange();
	const rows = document.querySelectorAll('#payments_table .payment-row:not(.payment-header):not(.empty)');
	rows.forEach(row => {
		const ts = parseInt(row.getAttribute('data-payment-time')) * 1000;
		row.style.display = (ts >= start && ts <= end) ? '' : 'none';
	});
}

/*------------------------
 * Data fetching and main flow
 *-----------------------*/

// Fetches account data, updates UI, sets graph annotations and renders payment table
function fetchAndRenderAccountInfo(graph) {
	return fetch(accountUrl)
		.then(r => r.json())
		.then(data => {
			accountData = data;
			updateRemainingKwhInfo();
			updateLastReadingStats();

			if (graph && graph.rawData_ && graph.rawData_.length > 0) {
				const labels = graph.getLabels();
				const seriesName = labels[1];
				const dataTimestamps = graph.rawData_.map(row => row[0]);

				// Snaps timestamp to closest timestamp in graph data for annotation positioning
				function snapToNearestTimestamp(target, timestamps) {
					let closest = timestamps[0];
					let minDiff = Math.abs(target - closest);
					for (let ts of timestamps) {
						let diff = Math.abs(target - ts);
						if (diff < minDiff) {
							closest = ts;
							minDiff = diff;
						}
					}
					return closest;
				}

				const markerAnnotations = data.account.map(entry => {
					let xVal = entry.payment_time * 1000;
					xVal = snapToNearestTimestamp(xVal, dataTimestamps);

					const typeMap = {
						payment: 'P',
						membership: 'M',
						charge: 'C',
					};
					const shortText = typeMap[entry.type] || '|';

					return {
						x: xVal,
						shortText: shortText,
						text: `#${entry.id}\n${entry.info}\n${entry.amount} kr`,
						series: seriesName,
						cssClass: 'custom-marker',
						annotationId: `payment-${entry.id}`
					};
				}).filter(a => a !== null);

				graph.setAnnotations(markerAnnotations);
				bindAnnotationEventsAndIds(graph);
				renderPaymentRowsFromAccountData(data.account);
				filterPaymentsBySelectedGraphRange(graph);
			}

			renderPaymentRowsFromAccountData(data.account);

			if (graph) {
				setTimeout(() => {
					filterPaymentsBySelectedGraphRange(graph); // ensure filter happens after table DOM exists
				}, 0);
			}

			return data;
		})
		.catch(err => {
			console.warn('Failed to refresh account data and UI:', err);
			if (graph) graph.setAnnotations([]);
			
			const errorEl = document.getElementById("error_message");
			if (errorEl) {
				errorEl.innerText = "⚠️ Unable to fetch latest account data.";
				errorEl.style.display = "block";
			}
		});
}

// --- MAIN FETCH AND UPDATE FUNCTION ---

function fetchAndUpdateGraph() {
	const currentRange = g ? g.xAxisRange() : null;

	return fetch(dataUrlCoarse)
		.then(r => r.text())
		.then(coarseCsv => {
			const coarseCsvMs = convertCsvSecondsToMs(coarseCsv);
			const now = Date.now();
			const oneYearAgo = now - 365 * 24 * 3600 * 1000;


			if (!g) {
				// Initial graph setup
				g = new Dygraph(
					document.getElementById("div_dygraph"),
					coarseCsvMs,
					{
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
						dateWindow: [oneYearAgo, now],
						interactionModel: Dygraph.defaultInteractionModel,
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
							strokeBorderWidth: 1,
						},
						zoomCallback: function(minX, maxX, yRanges) {
							updateConsumptionFromGraphRange();
							filterPaymentsBySelectedGraphRange(g);
						},
						drawCallback: (graph) => {
							const range = graph.xAxisRange();
							updateConsumptionFromGraphRange();
							filterPaymentsBySelectedGraphRange(graph);
							bindAnnotationEventsAndIds(graph);
						}
					}
				);
			} else {
				// Update data and nudge window forward 1 minute
				g.updateOptions({ file: coarseCsvMs });
				if (currentRange) {
					g.updateOptions({
						dateWindow: [currentRange[0] + 60000, currentRange[1] + 60000]
					});
				}
			}

			updateConsumptionFromGraphRange();

			return fetchAndRenderAccountInfo(g);
		})
		.then(() => {
			// ✅ Hide spinner after graph + annotations + table are ready
			const spinner = document.getElementById("graph_spinner");
			if (spinner) spinner.style.display = "none";
			
			// ✅ Start fine data fetch here
			return fetch(dataUrlFine);
		})
		.then(r => r.text())
		.then(fineCsv => {
			const fineCsvMs = convertCsvSecondsToMs(fineCsv);
			const mergedCsv = mergeCsv(g.file_, fineCsvMs);
			g.updateOptions({ file: mergedCsv });
			updateConsumptionFromGraphRange();
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

// INITIAL call
fetchAndUpdateGraph();

// PERIODIC updates every 60 seconds
setInterval(fetchAndUpdateGraph, 60000);
