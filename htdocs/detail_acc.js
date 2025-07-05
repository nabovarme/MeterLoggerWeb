var colorSets = [['#999999'], null];
var g;
var dataUrlCoarse = 'data/' + meter_serial + '/acc_coarse';
var dataUrlFine = 'data/' + meter_serial + '/acc_fine';
// markersUrl should return JSON array like [{ x: 1688563200000, label: "A", title: "Event A" }, ...]
var markersUrl = '/payments.json';

// Load initial coarse data and initialize graph
fetch(dataUrlCoarse)
	.then(r => r.text())
	.then(coarseCsv => {
		g = new Dygraph(
			document.getElementById("div_nabovarme"),
			coarseCsv,
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
			const mergedCsv = mergeCsv(g.file_, detailedCsv);
			g.updateOptions({ file: mergedCsv });

			// Now load markers and add annotations
			fetch(markersUrl)
				.then(r => r.json())
				.then(markers => {
					addMarkersToDygraph(g, markers);
				})
				.catch(() => {
					console.warn('Failed to load markers, skipping marker annotations');
				});
		});
}

// Merge CSVs by timestamp (assuming first column is timestamp string parseable by Date)
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
		return new Date(a.split(",")[0]) - new Date(b.split(",")[0]);
	});

	return [header].concat(sortedRows).join("\n");
}

// Add markers to Dygraph as annotations
// markers: array of {x: epoch ms, label: string, title: string}
function addMarkersToDygraph(graph, markerEntries) {
	if (!graph || !graph.setAnnotations) return;

	const labels = graph.getLabels();
	const seriesName = labels.length > 1 ? labels[1] : "";

	const annotations = markerEntries.map(entry => {
		let xVal = entry.x;
		if (typeof xVal === 'string') {
			xVal = parseInt(xVal, 10);  // string -> int (epoch ms)
		}
		if (!(xVal instanceof Date)) {
			xVal = new Date(xVal);  // epoch ms -> Date
		}

		return {
			x: xVal,
			shortText: '|',
			text: entry.text || '',
			series: seriesName,
			cssClass: 'custom-marker'
		};
	});

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
