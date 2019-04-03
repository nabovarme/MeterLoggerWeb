var data = [];
var colorSets = [
	['#999999'],
	null
]
var data = 'data/' + window.meter_serial + '/acc_low';
var g = new Dygraph(
	document.getElementById("div_nabovarme"), data, {
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
		highlightCallback: function(e) {
			update_consumption();
		},
		unhighlightCallback: function(e) {
			update_consumption();
		},
		zoomCallback: function(minDate, maxDate, yRanges) {
			update_consumption();
		},
		clickCallback: function(e, x, points) {
			update_consumption();
		},
//		showRangeSelector: true,	// , does not work with zoom
//		interactionModel: Dygraph.defaultInteractionModel
	}
);

g.ready(function () {
	update_consumption();
});

setInterval(function() {
	var range = g.xAxisRange();
	// update data and pan right
	range[0] += 60000;
	range[1] += 60000;
	g.updateOptions( { 'file': data, dateWindow: range } );
	update_last_energy();
	update_kwh_left();
	update_consumption();
}, 60000);

function update_consumption() {
	var range = g.xAxisRange();
	var minYinRange;
	var maxYinRange;
	var i;
	for (i = 0; i < g.rawData_.length; i++) {
		if (g.rawData_[i][0] >= range[0]) { 
			minYinRange = parseFloat(g.rawData_[i][1]);
			break;
		}
	}
	for (i = g.rawData_.length; i > 0; i--) {
		if (g.rawData_[i - 1][0] <= range[1]) { 
			maxYinRange = parseFloat(g.rawData_[i - 1][1]);
			break;
		}
	}
	var consumption = (maxYinRange - minYinRange);
	var average_consumption = consumption / ((range[1] - range[0]) / (1000 * 3600));				
	
	document.getElementById('consumption_in_range').innerHTML = 
		'<span class="default-bold">Consumption for selected period </span>' + 
		'<span class="default">' + 
		consumption.toFixed(2) + ' kWh, ' + 
		'at ' + average_consumption.toFixed(2) + ' kW/h' + 
		'</span>'
}

function formatDate(d) {
	var year = d.getFullYear(),
	month = d.getMonth() + 1,
	date = d.getDate(),
	hours = d.getHours(),
	minutes = d.getMinutes(),
	seconds = d.getSeconds();
	
	var now = new Date();
	if (d.getTime() < now.getTime() - (1000 * 86400)) {
		return 'Time: ' + date + '.' + month + '.' + year + ' ' + 
			hours + ':' + (minutes < 10 ? '0' : '') + minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
	}
	else {
		return 'Time: ' + hours + ':' + (minutes < 10 ? '0' : '') + minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
	}
}

g.ready(function () {
	// stop spinner
	spinner.stop();
});

function update_last_energy() {
	var xhttp = new XMLHttpRequest();
	xhttp.onreadystatechange = function() {
		if (xhttp.readyState == 4 && xhttp.status == 200) {
			document.getElementById("last_energy").innerHTML = xhttp.responseText;
		}
	};
	xhttp.open("GET", 'last_energy.epl?serial=' + window.meter_serial, true);
	xhttp.send();
}

function update_kwh_left() {
	var xhttp = new XMLHttpRequest();
	xhttp.onreadystatechange = function() {
		if (xhttp.readyState == 4 && xhttp.status == 200) {
			document.getElementById("kwh_left").innerHTML = xhttp.responseText;
		}
	};
	xhttp.open("GET", 'kwh_left.epl?serial=' + window.meter_serial, true);
	xhttp.send();
}
