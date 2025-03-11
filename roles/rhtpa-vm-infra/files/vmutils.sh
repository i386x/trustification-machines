# Virtual machine provisioning helpers

function __find_qcow2_image() {
    local _images="${1}"

    while read -r _line; do
        if [[ "${_line}" =~ \<a\ +href=\"([^\"]+\.qcow2)\"\ *\> ]]; then
            echo -n "${_images}/${BASH_REMATCH[1]}"
            break
        fi
    done < <(curl -k -L "${_images}" 2>&1)
}

function __get_fedora_images_url() {
    echo -n "https://download.fedoraproject.org/pub/fedora/linux/releases/${1}/Cloud/x86_64/images"
}

function get_fedora_image() {
    local _version="${1:-}"
    local _image="${2:-}"
    local _imageurl

    if [[ -z "${_version}" ]]; then
        echo "${FUNCNAME[0]}: Missing Fedora version" >&2
        return 1
    fi
    if [[ -z "${_image}" ]]; then
        echo "${FUNCNAME[0]}: Missing the path to the image" >&2
        return 1
    fi

    _imageurl="$(__get_fedora_images_url "${_version}")"
    _imageurl="$(__find_qcow2_image "${_imageurl}")"
    if [[ -z "${_imageurl}" ]]; then
        echo "${FUNCNAME[0]}: Unable to find QCOW2 image at $(__get_fedora_images_url "${_version}")" >&2
        return 1
    fi
    curl -k -L -o "${_image}" "${_imageurl}"
}

function genkeys() {
    local _vm="${1:-}"

    if [[ -z "${_vm}" ]]; then
        echo "${FUNCNAME[0]}: Missing virtual machine name" >&2
        return 1
    fi

    ssh-keygen -f ./id_rsa -t rsa -b 4096 -N "" -C "vm-${_vm}"
}

function __create_cloud_user_data() {
  cat > "${1}" <<-__EOF__
	#cloud-config
	users:
	  - default
	  - name: ${2}
	    ssh_authorized_keys:
	      - ${4}
	ssh_pwauth: True
	chpasswd:
	  list: |
	    ${2}:${3}
	  expire: False
	__EOF__
}

function create_cloud_init_metadata() (
    local _target="${1:-}"
    local _user="${2:-}"
    local _password="${3:-}"
    local _rsa="${4:-}"
    local _rsa_pub="${5:-}"

    if [[ -z "${_target}" ]]; then
        echo "${FUNCNAME[0]}: Missing target directory" >&2
        return 1
    fi
    if [[ -z "${_user}" ]]; then
        echo "${FUNCNAME[0]}: Missing user" >&2
        return 1
    fi
    if [[ -z "${_password}" ]]; then
        echo "${FUNCNAME[0]}: Missing password" >&2
        return 1
    fi
    if [[ -z "${_rsa}" ]]; then
        echo "${FUNCNAME[0]}: Missing path to the private RSA key" >&2
        return 1
    fi
    if [[ -z "${_rsa_pub}" ]]; then
        echo "${FUNCNAME[0]}: Missing path to the public RSA key" >&2
        return 1
    fi

    rm -rf "${_target}"
    mkdir -p "${_target}"
    cd "${_target}"

    if [[ ! -s "${_rsa}" ]]; then
        echo "${FUNCNAME[0]}: Private RSA key does not exist or it is an empty file" >&2
        return 1
    fi
    if [[ ! -s "${_rsa_pub}" ]]; then
        echo "${FUNCNAME[0]}: Public RSA key does not exist or it is an empty file" >&2
        return 1
    fi

    cp "${_rsa}" ./id_rsa
    chmod 600 ./id_rsa
    touch ./meta-data
    __create_cloud_user_data \
        ./user-data \
        "${_user}" \
        "${_password}" \
        "$(cat "${_rsa_pub}")"
)

function create_cloud_init_metadata_iso() (
    local _vm="${1:-}"
    local _iso="${2:-}"
    local _user="${3:-}"
    local _password="${4:-}"
    local _isodir

    if [[ -z "${_vm}" ]]; then
        echo "${FUNCNAME[0]}: Missing virtual machine name" >&2
        return 1
    fi
    if [[ -z "${_iso}" ]]; then
        echo "${FUNCNAME[0]}: Missing path to ISO file to be created" >&2
        return 1
    fi
    if [[ -z "${_user}" ]]; then
        echo "${FUNCNAME[0]}: Missing user" >&2
        return 1
    fi
    if [[ -z "${_password}" ]]; then
        echo "${FUNCNAME[0]}: Missing password" >&2
        return 1
    fi

    if [[ -s "${_iso}" && "${FORCE:-0}" -eq 0 ]]; then
      return 0
    fi

    _isodir="$(dirname "${_iso}")"
    mkdir -p "${_isodir}"

    cd "${_isodir}/.."
    if [[ ! -s ./id_rsa || ! -s ./id_rsa.pub || "${FORCE:-0}" -eq 1 ]]; then
        rm -vf ./id_rsa ./id_rsa.pub
        genkeys "${_vm}"
    fi

    create_cloud_init_metadata \
        "${_isodir}" \
        "${_user}" \
        "${_password}" \
        "${_isodir}/../id_rsa" \
        "${_isodir}/../id_rsa.pub"

    cd "${_isodir}"
    mkisofs \
        -input-charset utf-8 \
        -volid cidata \
        -joliet \
        -rock \
        -output "${_iso}" \
        ./user-data \
        ./meta-data
)

function remote_sxx() {
    local _sxx="${1:-}"
    local _id_rsa="${2:-}"
    declare -a _sxx_params=()

    if [[ "${_sxx}" != ssh && "${_sxx}" != scp ]]; then
        echo "$0: First argument must be either \`ssh\` or \`scp\`" >&2
        return 1
    fi
    if [[ -z "${_id_rsa}" || ! -s "${_id_rsa}" ]]; then
        echo "$0: Missing SSH private key file" >&2
        return 1
    fi

    shift 2

    _sxx_params+=( ${SXX_COMMON_ARGS:-} -o LogLevel=ERROR -i "${_id_rsa}" )
    if [[ "${_sxx}" == ssh ]]; then
        _sxx_params+=( -t )
    fi

    timeout ${SXX_TIMEOUT:-0} "${_sxx}" "${_sxx_params[@]}" "$@"
}

function remote_ssh() {
    remote_sxx ssh "$@"
}

function remote_sshq() {
    remote_ssh "$@" >/dev/null 2>&1
}

function remote_scp() {
    remote_sxx scp "$@"
}

function discover_python_interpreter() {
    local _python

    for _item in python3 python /usr/libexec/platform-python; do
        _python="$(${1:-} command -v "${_item}" 2>/dev/null)" || :
        if [[ -n "${_python}" ]]; then
            echo -n "${_python}"
            return
        fi
    done
    return 1
}
