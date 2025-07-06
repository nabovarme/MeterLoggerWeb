var colorSets = [['#999999'], null];
var g;
var dataUrlCoarse = '/api/data_acc/' + meter_serial + '/coarse';
var dataUrlFine = '/api/data_acc/' + meter_serial + '/fine';
// markersUrl should return JSON array like [{ x: 1688563200000, label: "A", title: "Event A" }, ...]
var markersUrl = '/payments.json';

// Convert CSV timestamps from seconds to milliseconds
function convertCsvSecondsToMs(csv) {
	const lines = csv.trim().split("\n");
	const header = lines[0];
	const convertedLines = lines.slice(1).map(line => {
		const parts = line.split(",");
		// Convert timestamp to milliseconds (number), not ISO string
		parts[0] = (parseInt(parts[0], 10) * 1000).toString();
		return parts.join(",");
	});
	return [header, ...convertedLines].join("\n");
}

// Load initial coarse data and initialize graph
fetch(dataUrlCoarse)
	.then(r => r.text())
	.then(coarseCsv => {
		const coarseCsvMs = convertCsvSecondsToMs(coarseCsv);

		g = new Dygraph(
			document.getElementById("div_nabovarme"),
			coarseCsvMs,
			{
				colors: colorSets[0],
				strokeWidth: 1.5,
				animatedZooms: true,
				showLabelsOnHighlight: true,
				labelsDivStyles: {
					'font-family': 'Verdana, Geneva, sans-serif',
					'text-align': 'left',
					'background': 'none'
				},
				labelsSeparateLines: true,
				labelsDivWidth: 700,
				axes: {
					x: {
						valueFormatter: function(x) {
							return formatDate(new Date(x));
						},
						axisLabelFormatter: function(x) {
							const d = new Date(x);
							// Example: 06 Jul 13:30
							return `${d.getDate().toString().padStart(2, '0')} ${d.toLocaleString('default', { month: 'short' })} ${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
						}
					}
				},
				maxNumberWidth: 12,
				highlightSeriesOpts: {
					pointSize: 6,
					highlightCircleSize: 6,
					strokeWidth: 2,
					strokeBorderWidth: 1,
				},
				highlightCallback: update_consumption,
				unhighlightCallback: update_consumption,
				zoomCallback: update_consumption,
				clickCallback: update_consumption,
			}
		);

		g.ready(function () {
			update_consumption();
			loadAndMergeDetailedData();
		});

		setInterval(function() {
			const range = g.xAxisRange();
			g.updateOptions({
				file: g.file_,
				dateWindow: [range[0] + 60000, range[1] + 60000]
			});
			update_last_energy();
			update_kwh_left();
			update_consumption();
		}, 60000);
	});

// Load and merge detailed data, then load markers and add annotations
function loadAndMergeDetailedData() {
	fetch(dataUrlFine)
		.then(r => r.text())
		.then(detailedCsv => {
			const detailedCsvMs = convertCsvSecondsToMs(detailedCsv);
			const mergedCsv = mergeCsv(g.file_, detailedCsvMs);
			g.updateOptions({ file: mergedCsv });

			// Now load markers and add annotations
			// If markers come in seconds, convert them here; example uses ms timestamps
//			fetch(markersUrl)
//				.then(r => r.json())
//				.then(markers => {
//					addMarkersToDygraph(g, markers);
//				})
//				.catch(() => {
//					console.warn('Failed to load markers, skipping marker annotations');
//				});
			const testMarkers = [
				{ x: 1751751485000, label: "T", title: "Test marker now" },
				{ x: 1751543685000, label: "P", title: "Test marker 1 hour ago" }
			];
			addMarkersToDygraph(g, testMarkers);
		});
}

// Merge CSVs by timestamp (timestamps expected in milliseconds)
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
		// Numeric compare for timestamps in ms
		return parseInt(a.split(",")[0], 10) - parseInt(b.split(",")[0], 10);
	});

	return [header].concat(sortedRows).join("\n");
}

// Add markers to Dygraph as annotations
function addMarkersToDygraph(graph, markerEntries) {
	if (!graph || !graph.setAnnotations) return;

	const labels = graph.getLabels();
	const seriesName = labels.length > 1 ? labels[1] : "";

	// Extract all existing timestamps (x values) from the Dygraph data
	const dataTimestamps = graph.rawData_.map(row => row[0]);

	// Helper: find closest timestamp in data to given target
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

	const annotations = markerEntries.map(entry => {
		let xVal = entry.x;
		if (typeof xVal === 'string') {
			xVal = parseInt(xVal, 10);
		}

		// Expect xVal in milliseconds
		if (typeof xVal === 'number') {
			xVal = snapToNearestTimestamp(xVal, dataTimestamps);
		}

		if (!(xVal instanceof Date)) {
			xVal = new Date(xVal);
		}

		if (isNaN(xVal.getTime())) {
			console.warn('Invalid marker x value:', entry.x);
			return null;
		}

		return {
			x: xVal,
			shortText: entry.label || '|',
			text: entry.title || '',
			series: seriesName,
			cssClass: 'custom-marker'
		};
	}).filter(a => a !== null);

	console.log("Setting annotations:", annotations);
	console.log("Dygraph labels:", graph.getLabels());
	graph.setAnnotations(annotations);
}

function update_consumption() {
	if (!g || !g.rawData_) return;

	const range = g.xAxisRange();
	let minY, maxY;

	for (let i = 0; i < g.rawData_.length; i++) {
		if (g.rawData_[i][0] >= range[0]) {
			minY = parseFloat(g.rawData_[i][1]);
			break;
		}
	}

	for (let i = g.rawData_.length - 1; i >= 0; i--) {
		if (g.rawData_[i][0] <= range[1]) {
			maxY = parseFloat(g.rawData_[i][1]);
			break;
		}
	}

	const consumption = (maxY - minY);
	const avg = consumption / ((range[1] - range[0]) / (1000 * 3600));

	document.getElementById('consumption_in_range').innerHTML =
		'<span class="default-bold">Consumption for selected period </span>' +
		'<span class="default">' +
		consumption.toFixed(2) + ' kWh, at ' + avg.toFixed(2) + ' kW/h</span>';
}

function formatDate(d) {
	const pad = (n) => (n < 10 ? '0' + n : n);
	const now = new Date();
	if (d.getTime() < now.getTime() - (1000 * 86400)) {
		return `Time: ${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	} else {
		return `Time: ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	}
}

function update_last_energy() {
	fetch('last_energy.epl?serial=' + meter_serial)
		.then(response => {
			if (!response.ok) throw new Error('Network response was not ok');
			return response.text();
		})
		.then(data => {
			document.getElementById("last_energy").innerHTML = data;
		})
		.catch(error => console.error('Fetch error:', error));
}

function update_kwh_left() {
	fetch('kwh_left.epl?serial=' + meter_serial)
		.then(response => {
			if (!response.ok) throw new Error('Network response was not ok');
			return response.text();
		})
		.then(data => {
			document.getElementById("kwh_left").innerHTML = data;
		})
		.catch(error => console.error('Fetch error:', error));
}
