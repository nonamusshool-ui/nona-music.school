const kyivClock = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/Kyiv", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});

export function dateKey(date) {
  return date.toISOString().slice(0, 10);
}

export function mondayOf(day) {
  const date = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(date.getTime()) || dateKey(date) !== day) throw new Error("Invalid calendar day");
  date.setUTCDate(date.getUTCDate() - (date.getUTCDay() + 6) % 7);
  return dateKey(date);
}

export function shiftDay(day, amount) {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + amount);
  return dateKey(date);
}

// Resolve each Kyiv midnight separately. The UTC offset can change between
// Mondays when a week contains a daylight-saving transition.
export function kyivMidnightUtc(day) {
  const wall = Date.parse(`${day}T00:00:00Z`);
  if (Number.isNaN(wall) || dateKey(new Date(wall)) !== day) throw new Error("Invalid calendar day");
  let instant = wall;
  for (let i = 0; i < 3; i++) {
    const parts = Object.fromEntries(kyivClock.formatToParts(new Date(instant))
      .map(({ type, value }) => [type, value]));
    const viewed = Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day),
      Number(parts.hour), Number(parts.minute));
    instant += wall - viewed;
  }
  const check = Object.fromEntries(kyivClock.formatToParts(new Date(instant))
    .map(({ type, value }) => [type, value]));
  if (`${check.year}-${check.month}-${check.day}` !== day || check.hour !== "00" || check.minute !== "00") {
    throw new Error("Kyiv midnight could not be resolved");
  }
  return new Date(instant).toISOString();
}
