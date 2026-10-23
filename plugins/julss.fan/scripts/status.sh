#!/bin/bash
# Estado del ventilador para el panel julss.fan, una línea "clave valor" por dato.
# temp = la más alta de coretemp (la misma que usa mbpfan).
smc="" core=""
for h in /sys/class/hwmon/hwmon*; do
  case $(<"$h/name") in
    applesmc) smc=$h ;;
    coretemp) core=$h ;;
  esac
done 2>/dev/null

echo "active $(systemctl is-active mbpfan.service 2>/dev/null)"
if [[ -n $core ]]; then
  t=0
  for f in "$core"/temp*_input; do v=$(<"$f"); (( v > t )) && t=$v; done
  echo "temp $((t / 1000))"
fi
if [[ -n $smc ]]; then
  echo "rpm $(<"$smc/fan1_input")"
  echo "hwmin $(<"$smc/fan1_min")"
  echo "hwmax $(<"$smc/fan1_max")"
  # pwm1_enable (kernel nuevo): 1 manual (mbpfan), 2 firmware. fan1_manual (viejo): 1/0.
  if [[ -r $smc/pwm1_enable ]]; then echo "mode $(<"$smc/pwm1_enable")"
  elif [[ -r $smc/device/fan1_manual ]]; then m=$(<"$smc/device/fan1_manual"); echo "mode $(( m == 1 ? 1 : 2 ))"; fi
fi
[[ -x /usr/local/bin/julss-fan-apply ]] && echo "helper 1" || echo "helper 0"
