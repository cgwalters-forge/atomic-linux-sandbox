#!/usr/bin/bash
# Sourced by 10-build.sh and 40-variant.sh. apply_drop_ins DIR applies a
# directory of drop-ins, each part optional:
#   DIR/packages/*.txt  packages to install, one name per line
#   DIR/system/         files copied onto /; its presets are also applied
#   DIR/units/*.enable  units to enable, one name per line
# In the lists, # starts a comment.

# Print the entries of the list files given.
read_list() {
	(($#)) || return 0
	sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"
}

# Packages come first so that the overlay replaces their default
# configuration instead of leaving it as .rpmnew files.
apply_drop_ins() {
	local dir=$1 restore out unit
	local -a packages units presets
	# shopt -p exits 1 when the option is off.
	restore=$(shopt -p nullglob || true)
	shopt -s nullglob

	echo "::group:: Drop-ins from ${dir}"
	# Presets are the exception: installing a package applies them, so they
	# must be in place first.
	if [[ -d "${dir}/system/usr/lib/systemd/system-preset" ]]; then
		rsync -rvK "${dir}/system/usr/lib/systemd/system-preset/" /usr/lib/systemd/system-preset/
	fi

	out=$(read_list "${dir}"/packages/*.txt)
	if [[ -n "${out}" ]]; then
		mapfile -t packages <<<"${out}"
		dnf5 install -y "${packages[@]}"
	fi

	if [[ -d "${dir}/system" ]]; then
		rsync -rvK "${dir}/system/" /
	fi

	# Apply the drop-ins' own presets to the installed units they name, so
	# units the base image already had pick up the new defaults too.
	presets=("${dir}"/system/usr/lib/systemd/system-preset/*.preset)
	units=()
	if ((${#presets[@]})); then
		while read -r unit; do
			if [[ -e "/usr/lib/systemd/system/${unit}" ]]; then
				units+=("${unit}")
			fi
		done < <(awk '$1 == "enable" || $1 == "disable" { print $2 }' "${presets[@]}")
	fi
	if ((${#units[@]})); then
		systemctl preset "${units[@]}"
	fi

	# Explicit enablement overrides preset defaults at build time.
	out=$(read_list "${dir}"/units/*.enable)
	if [[ -n "${out}" ]]; then
		mapfile -t units <<<"${out}"
		systemctl enable "${units[@]}"
	fi
	echo "::endgroup::"

	eval "${restore}"
}
