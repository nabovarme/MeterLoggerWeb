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

// Converts CSV timestamps from seconds to milliseconds (Dygraph expects ms)
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

// ✅ Refactored: Fetches account data, updates UI, sets annotations, renders table
function refreshAccountInfo(graph) {
	return fetch(accountUrl)
		.then(r => r.json())
		.then(data => {
			accountData = data;
			update_kwh_left();
			update_last_energy();

			if (graph && graph.rawData_ && graph.rawData_.length > 0) {
				const labels = graph.getLabels();
				const seriesName = labels[1];
				const dataTimestamps = graph.rawData_.map(row => row[0]);

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
						text: `${entry.info}\n${entry.amount} kr`,
						series: seriesName,
						cssClass: 'custom-marker'
					};
				}).filter(a => a !== null);

				graph.setAnnotations(markerAnnotations);
			}

			renderPaymentsTableFromMarkers(data.account);
			return data;
		})
		.catch(err => {
			console.warn('Failed to refresh account data and UI:', err);
			if (graph) graph.setAnnotations([]);
		});
}

// Builds a table of payment records below the graph
function renderPaymentsTableFromMarkers(payments) {
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

// Initial fetch of coarse data and graph setup
fetch(dataUrlCoarse)
	.then(r => r.text())
	.then(coarseCsv => {
		const coarseCsvMs = convertCsvSecondsToMs(coarseCsv);

		g = new Dygraph(
			document.getElementById("div_dygraph"),
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
				zoomCallback: update_consumption,
			}
		);

		g.ready(() => {
			refreshAccountInfo(g).then(() => {
				update_consumption();
			});
			loadAndMergeDetailedData();
		});

		setInterval(function() {
			const range = g.xAxisRange();
			refreshAccountInfo(g).then(() => {
				g.updateOptions({
					file: g.file_,
					dateWindow: [range[0] + 60000, range[1] + 60000]
				});
				update_consumption();
			});
		}, 60000);
	});

// Loads more fine-grained data and merges with existing graph
function loadAndMergeDetailedData() {
	fetch(dataUrlFine)
		.then(r => r.text())
		.then(detailedCsv => {
			const detailedCsvMs = convertCsvSecondsToMs(detailedCsv);
			const mergedCsv = mergeCsv(g.file_, detailedCsvMs);
			g.updateOptions({ file: mergedCsv });

			refreshAccountInfo(g);
		});
}

// Merges two CSVs, avoiding duplicates, keeping latest entry per timestamp
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

// Updates the displayed energy use over the currently selected graph range
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

// Formats timestamps for display
function formatDate(d) {
	const pad = (n) => (n < 10 ? '0' + n : n);
	const now = new Date();
	if (d.getTime() < now.getTime() - (1000 * 86400)) {
		return `Time: ${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	} else {
		return `Time: ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
	}
}

// Loads and updates the most recent energy reading from a separate endpoint
function update_last_energy() {
	document.getElementById("last_energy").innerHTML = normalizeAmount(accountData.last_energy) + " kWh<br> " + normalizeAmount(accountData.last_volume) + " m<sup>3</sup><br>" + normalizeAmount(accountData.last_hours) + " hours<br>";
}

function update_kwh_left() {
	if (accountData && accountData.kwh_left != null) {
		document.getElementById("kwh_left").innerHTML = normalizeAmount(accountData.kwh_left) + " kWh left, " + accountData.time_left_str + " at " + accountData.avg_energy_last_day + " kWh/h";
	}
}

// Helper to ensure all amounts show with 2 decimals
function normalizeAmount(amount) {
	return parseFloat(amount).toFixed(2);
}
