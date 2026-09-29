let alarmTemplates = [];

function secToHHMM(sec) {
	if (sec === null || sec === undefined || sec === '') return '';
	const s = Number(sec);
	if (isNaN(s)) return '';
	return `${String(Math.floor(s / 3600)).padStart(2, '0')}:${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}`;
}

document.addEventListener('DOMContentLoaded', async () => {
	const params = new URLSearchParams(window.location.search);
	const alarmId = params.get('id');
	const statusMsg = document.getElementById('statusMsg');
	const textarea = document.getElementById('conditionField');
	const popup = document.getElementById('condition-popup');

	if (!alarmId) {
		statusMsg.className = 'status-msg status-error';
		statusMsg.textContent = 'Missing alarm ID in URL';
		statusMsg.style.display = 'block';
		return;
	}

	// ==========================================
	// 1. Fetch Alarm Templates for Autocomplete
	// ==========================================
	async function fetchAlarmTemplates() {
		try {
			const res = await fetch('/api/alarm_templates');
			if (res.ok) {
				alarmTemplates = await res.json();
			}
		} catch (e) {
			console.warn('Could not load alarm templates:', e);
		}
	}

	// ==========================================
	// 2. Fetch and Populate Alarm Details
	// ==========================================
	async function loadAlarm() {
		try {
			const res = await fetch(`/api/alarm_detail?id=${alarmId}`);
			const data = await res.json();

			if (!data.success || !data.alarm) {
				throw new Error(data.error || 'Failed to load alarm');
			}

			const a = data.alarm;
			document.getElementById('alarmCard').style.display = 'block';

			if (Number(a.condition_state) > 0 && Number(a.enabled) > 0) {
				document.getElementById('alarmCard').className = 'alarm-state';
			} else {
				document.getElementById('alarmCard').className = '';
			}

			document.getElementById('headline').innerHTML = `<a href="detail.epl?serial=${a.serial}">${a.serial}</a> ${a.info || ''}`;
			document.title = `Meterlogger alarm detail - ${a.info || ''} ${a.serial}`;
			document.getElementById('alarmId').value = a.id;
			document.getElementById('enabled').checked = Boolean(Number(a.enabled));

			if (a.auto_id) {
				document.getElementById('autoSection').style.display = 'block';
				document.getElementById('ignoreAutoUpdate').checked = Boolean(Number(a.ignore_auto_update));
				document.getElementById('ignoreAutoHint').textContent = Number(a.ignore_auto_update)
					? '⚠ This alarm is manually managed (not synced with template)'
					: '✓ This alarm follows template updates';
			} else {
				document.getElementById('autoSection').style.display = 'none';
			}

			// Format receiver phone number if valid
			let formattedPhone = a.sms_notification || '';
			if (formattedPhone && typeof NabovarmeNumberPhone !== 'undefined') {
				const phone = NabovarmeNumberPhone.new(formattedPhone);
				if (phone && phone.isValid()) {
					formattedPhone = phone.compact();
				}
			}
			document.getElementById('smsNotification').value = formattedPhone;

			document.getElementById('smsEnabled').checked = Boolean(Number(a.sms_enabled ?? 1));
			document.getElementById('pushEnabled').checked = Boolean(Number(a.push_enabled ?? 0));
			
			textarea.value = a.condition || '';
			if (a.condition_error) {
				textarea.classList.add('label-red-border');
			} else {
				textarea.classList.remove('label-red-border');
			}

			document.getElementById('activeFrom').value = secToHHMM(a.active_from_sec);
			document.getElementById('activeTo').value = secToHHMM(a.active_to_sec);
			document.getElementById('timezone').value = a.timezone || 'Europe/Copenhagen';
			
			document.getElementById('repeat').value = a.repeat || 0;
			document.getElementById('defaultSnooze').value = a.default_snooze || 1800;
			document.getElementById('upMessage').value = a.up_message || '';
			document.getElementById('downMessage').value = a.down_message || '';
			document.getElementById('comment').value = a.comment || '';

			if (a.is_admin) {
				document.getElementById('submitBtnWrapper').style.display = 'block';
			}
		} catch (err) {
			statusMsg.className = 'status-msg status-error';
			statusMsg.textContent = err.message;
			statusMsg.style.display = 'block';
		}
	}

	// ==========================================
	// 3. Submit Form Updates via API
	// ==========================================
	document.getElementById('alarmForm').addEventListener('submit', async (e) => {
		e.preventDefault();
		statusMsg.style.display = 'none';

		const payload = {
			enabled: document.getElementById('enabled').checked ? 1 : 0,
			ignore_auto_update: document.getElementById('ignoreAutoUpdate')?.checked ? 1 : 0,
			sms_notification: document.getElementById('smsNotification').value,
			sms_enabled: document.getElementById('smsEnabled').checked ? 1 : 0,
			push_enabled: document.getElementById('pushEnabled').checked ? 1 : 0,
			condition: textarea.value,
			active_from: document.getElementById('activeFrom').value,
			active_to: document.getElementById('activeTo').value,
			timezone: document.getElementById('timezone').value,
			repeat: document.getElementById('repeat').value,
			default_snooze: document.getElementById('defaultSnooze').value,
			up_message: document.getElementById('upMessage').value,
			down_message: document.getElementById('downMessage').value,
			comment: document.getElementById('comment').value
		};

		try {
			const res = await fetch(`/api/alarm_detail?id=${alarmId}`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(payload)
			});

			const data = await res.json();
			if (!data.success) throw new Error(data.error || 'Update failed');

			statusMsg.className = 'status-msg status-success';
			statusMsg.textContent = 'Alarm updated successfully';
			statusMsg.style.display = 'block';

			await loadAlarm();
		} catch (err) {
			statusMsg.className = 'status-msg status-error';
			statusMsg.textContent = err.message;
			statusMsg.style.display = 'block';
		}
	});

	// ==========================================
	// 4. '@' Template Autocomplete Logic
	// ==========================================
	let triggerIndex = -1;
	const mirrorDiv = document.createElement('div');
	document.body.appendChild(mirrorDiv);

	const style = getComputedStyle(textarea);
	const properties = [
		'boxSizing', 'width', 'height', 'overflowX', 'overflowY',
		'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
		'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
		'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'letterSpacing',
		'textTransform', 'wordSpacing', 'lineHeight', 'tabSize', 'MozTabSize'
	];
	properties.forEach(prop => { mirrorDiv.style[prop] = style[prop]; });

	mirrorDiv.style.position = 'absolute';
	mirrorDiv.style.visibility = 'hidden';
	mirrorDiv.style.whiteSpace = 'pre-wrap';
	mirrorDiv.style.wordWrap = 'break-word';
	mirrorDiv.style.top = '0';
	mirrorDiv.style.left = '-9999px';

	function showPopupAtCaret(cursorPos) {
		popup.innerHTML = '';
		if (!alarmTemplates.length) return;

		alarmTemplates.forEach(opt => {
			const div = document.createElement('div');
			div.className = 'popup-item';
			div.innerHTML = `<div class="popup-label">${opt.label || opt.description}</div>`;

			div.onclick = () => {
				insertCondition(opt.condition);
				hidePopup();
			};
			popup.appendChild(div);
		});

		const caret = getCaretCoordinates(textarea, cursorPos);
		const rect = textarea.getBoundingClientRect();

		popup.style.left = rect.left + window.scrollX + caret.left + 'px';
		popup.style.top = rect.top + window.scrollY + caret.top + 'px';
		popup.style.display = 'block';
	}

	function hidePopup() {
		popup.style.display = 'none';
	}

	function insertCondition(condition) {
		const text = textarea.value;
		const before = text.substring(0, triggerIndex);
		const after = text.substring(textarea.selectionEnd);

		textarea.value = before + condition + " " + after;
		const pos = (before + condition + " ").length;
		textarea.focus();
		textarea.setSelectionRange(pos, pos);
	}

	function onInput() {
		const cursorPos = textarea.selectionStart;
		const text = textarea.value;
		const lastAt = text.lastIndexOf('@', cursorPos - 1);

		if (lastAt !== -1 && (cursorPos - lastAt <= 30)) {
			triggerIndex = lastAt;
			showPopupAtCaret(cursorPos);
		} else {
			hidePopup();
		}
	}

	textarea.addEventListener('input', onInput);
	textarea.addEventListener('scroll', onInput);

	document.addEventListener('click', (e) => {
		if (!popup || !textarea) return;
		if (!popup.contains(e.target) && e.target !== textarea) {
			hidePopup();
		}
	});

	function getCaretCoordinates(element, position) {
		const div = mirrorDiv;
		const value = element.value.substring(0, position);
		const safeValue = value.replace(/\n$/g, '\n\u200b').replace(/ /g, '\u00a0');

		div.textContent = safeValue;
		const span = document.createElement('span');
		span.textContent = element.value.substring(position) || '.';
		div.appendChild(span);

		return { left: span.offsetLeft, top: span.offsetTop };
	}

	// Initialize page
	await fetchAlarmTemplates();
	await loadAlarm();
});
