var colorSets = [['#999999'], null];
var g;
//var meter_serial = '123456'; // Replace this dynamically if needed
var dataUrlCoarse = 'data/' + meter_serial + '/acc_coarse';
var dataUrlFine = 'data/' + meter_serial + '/acc_fine';

// Load initial coarse data
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

		// Pan right every minute
		setInterval(function() {
			const range = g.xAxisRange();
			g.updateOptions({
				file: coarseCsv,
				dateWindow: [range[0] + 60000, range[1] + 60000]
			});
			update_last_energy();
			update_kwh_left();
			update_consumption();
		}, 60000);
	});

// Load and merge detailed data
function loadAndMergeDetailedData() {
	fetch(dataUrlFine)
		.then(r => r.text())
		.then(detailedCsv => {
			const mergedCsv = mergeCsv(g.file_, detailedCsv);
			g.updateOptions({ file: mergedCsv });
		});
}

// Merge CSVs by timestamp
function mergeCsv(csv1, csv2) {
	const lines1 = csv1.trim().split("\n");
	const lines2 = csv2.trim().split("\n");
	
	const header = lines1[0];
	const allLines = lines1.slice(1).concat(lines2.slice(1));
	
	// Use a Map to remove duplicates by timestamp
	const uniqueRows = new Map();
	for (const line of allLines) {
		const timestamp = line.split(",")[0]; // assumes timestamp is the first column
		uniqueRows.set(timestamp, line); // newer value overwrites older
	}
	
	// Sort by timestamp
	const sortedRows = Array.from(uniqueRows.values()).sort((a, b) => {
		return new Date(a.split(",")[0]) - new Date(b.split(",")[0]);
	});
	
	return [header].concat(sortedRows).join("\n");
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
			if (!response.ok) {
				throw new Error('Network response was not ok');
			}
			return response.text();
		})
		.then(data => {
			document.getElementById("last_energy").innerHTML = data;
		})
		.catch(error => {
			console.error('Fetch error:', error);
		});
}

function update_kwh_left() {
	fetch('kwh_left.epl?serial=' + meter_serial)
		.then(response => {
			if (!response.ok) {
				throw new Error('Network response was not ok');
			}
			return response.text();
		})
		.then(data => {
			document.getElementById("kwh_left").innerHTML = data;
		})
		.catch(error => {
			console.error('There was a problem with the fetch operation:', error);
		});
}
