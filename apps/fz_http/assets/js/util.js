import zxcvbn from "zxcvbn"

const dateFormatter = new Intl.DateTimeFormat(
  'en-US',
  {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: 'numeric'
  }
)

const FormatTimestamp = function (timestamp) {
  if (timestamp) {
    return dateFormatter.format(new Date(timestamp))
  } else {
    return "Never"
  }
}

const PasswordStrength = function (password) {
  const result = zxcvbn(password)
  return result.score
}

export { PasswordStrength, FormatTimestamp }
