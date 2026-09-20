/* CNResetCopy.swift / Codenotch MIT. Calendar-day based absolute dates and rounded countdowns. */
(function (root) {
  const millis = (value) =>
    value instanceof Date
      ? value.getTime()
      : typeof value === "number"
        ? value
        : typeof value === "string"
          ? Date.parse(value)
          : NaN;
  function daysApart(from, to, timeZone) {
    const f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      calendar: "gregory",
      year: "numeric",
      month: "numeric",
      day: "numeric",
    });
    const day = (value) => {
      const p = Object.fromEntries(
        f
          .formatToParts(value)
          .filter((x) => x.type !== "literal")
          .map((x) => [x.type, +x.value]),
      );
      return Date.UTC(p.year, p.month - 1, p.day) / 86400000;
    };
    return Math.round(day(to) - day(from));
  }
  function text(
    value,
    { now = Date.now(), format = "automatic", locale = "zh-CN", timeZone } = {},
  ) {
    const at = millis(value),
      current = millis(now),
      chinese = /^zh/i.test(locale);
    if (!Number.isFinite(at) || !Number.isFinite(current))
      return chinese ? "暂未提供重置时间" : "Reset time unavailable";
    const seconds = (at - current) / 1000;
    if (seconds <= 0) return chinese ? "正在重置…" : "Resetting…";
    const minutes = Math.max(1, Math.round(seconds / 60)),
      hours = Math.floor(minutes / 60),
      days = Math.floor(hours / 24);
    if (format === "remaining") {
      if (days > 0)
        return chinese
          ? `${days} 天 ${hours % 24}小时后重置`
          : `Resets in ${days} ${days === 1 ? "Day" : "Days"} ${hours % 24}h`;
      if (hours > 0)
        return chinese
          ? `${hours}小时 ${minutes % 60}分后重置`
          : `Resets in ${hours}h ${minutes % 60}m`;
      return chinese ? `${minutes} 分钟后重置` : `Resets in ${minutes} min`;
    }
    if (minutes < 60)
      return chinese ? `${minutes} 分钟后重置` : `Resets in ${minutes} min`;
    const options =
      daysApart(current, at, timeZone) >= 7
        ? { month: "short", day: "numeric" }
        : { weekday: "short", hour: "2-digit", minute: "2-digit" };
    const absolute = new Intl.DateTimeFormat(locale, {
      ...options,
      timeZone,
    }).format(at);
    return chinese ? absolute + "重置" : "Resets " + absolute;
  }
  const api = { text, daysApart };
  if (typeof module !== "undefined") module.exports = api;
  else root.ResetCopy = api;
})(globalThis);
