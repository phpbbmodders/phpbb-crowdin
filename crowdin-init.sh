#!/usr/bin/bash
#
# crowdin-init.sh - Synchronize a phpBB extension with its Crowdin project.
#
# Purpose:
#   Creates or updates the Crowdin project backing a phpBB extension's
#   localization, ensures the custom phpBB language variants (formal /
#   casual honorific dialects) and full phpBB target language set exist
#   on Crowdin, then either uploads source strings to Crowdin or
#   downloads completed translations back into the extension, using the
#   Crowdin CLI driven by a runtime-generated crowdin.yml built from
#   crowdin.yml.template.
#
# Usage:
#   crowdin-init.sh [OPTIONS] [EXTENSION_PATH]
#
#   Run with -h/--help for the full option list. EXTENSION_PATH is the
#   phpBB extension directory (defaults to the current directory); the
#   extension's composer.json supplies its identity (vendor/package,
#   display name, description).
#
# Inputs:
#   crowdin.conf (or the file given via -c/--config) - optional shared
#     project configuration (name, identifier, description, visibility,
#     language access policy, source sync toggle, CLI template path).
#   composer.json in the resolved extension root - required; supplies
#     defaults for project identifier/name/description.
#   CROWDIN_API_TOKEN - required Crowdin Personal Access Token.
#   CROWDIN_PROJECT_ID - optional numeric project ID override, used
#     instead of looking the project up by identifier.
#
# Outputs:
#   Colorized progress/status messages on stdout, errors on stderr.
#   Source files are uploaded to Crowdin, or completed translations are
#   downloaded into the extension tree, depending on the selected mode.
#
# Exit status:
#   0 on success, 1 on any validation, API, or Crowdin CLI failure.
#
# Dependencies:
#   bash, curl, jq, and (for source sync / translation download) the
#   Crowdin CLI (`crowdin`).

set -Eeuo pipefail


# ==============================================================================
# Constants
# ==============================================================================

CROWDIN_API_BASE="https://api.crowdin.com/api/v2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


# ==============================================================================
# Script Directory
# ==============================================================================

SCRIPT_DIR=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd
)


# ==============================================================================
# Defaults
# ==============================================================================

DRY_RUN=false
DOWNLOAD_MODE=false
DOWNLOAD_DRY_RUN=false

CONFIG_FILE="$SCRIPT_DIR/crowdin.conf"
CROWDIN_CLI_TEMPLATE="$SCRIPT_DIR/crowdin.yml.template"

SOURCE_LANGUAGE="en"

PROJECT_NAME=""
PROJECT_IDENTIFIER=""
PROJECT_DESCRIPTION=""

PROJECT_VISIBILITY="open"
LANGUAGE_ACCESS_POLICY="open"

SOURCE_SYNC=true

EXTENSION_PATH="."

CROWDIN_API_TOKEN="${CROWDIN_API_TOKEN:-}"
CROWDIN_PROJECT_ID="${CROWDIN_PROJECT_ID:-}"

CONFIG_SET_PROJECT_NAME=false
CONFIG_SET_PROJECT_DESCRIPTION=false
CONFIG_SET_PROJECT_VISIBILITY=false
CONFIG_SET_LANGUAGE_ACCESS_POLICY=false

EXTENSION_ROOT=""
COMPOSER_FILE=""

COMPOSER_PACKAGE=""
COMPOSER_VENDOR=""
COMPOSER_IDENTIFIER=""
COMPOSER_DISPLAY_NAME=""
COMPOSER_DESCRIPTION=""
COMPOSER_TYPE=""

PROJECT_ID=""
CURRENT_PROJECT=""

HTTP_STATUS=""

API_RESPONSE_FILE=""
RUNTIME_CROWDIN_CONFIG=""


# ==============================================================================
# Custom phpBB Language Variants
# ==============================================================================
#
# Format:
#
#   Crowdin ID|Name|Dialect Of|Three Letter Code
#
# These custom Crowdin languages allow phpBB variants to exist independently
# from their base languages.
#
# ==============================================================================

CUSTOM_LANGUAGES=(
    'de-x-sie|German (Formal Honorifics)|de|des'
    'es-x-tu|Spanish (Casual Honorifics)|es-ES|esx'
    'nl-x-formal|Dutch (Formal Honorifics)|nl|nlx'
    'hr-x-vi|Croatian (Formal Honorifics)|hr|hrx'
)


# ==============================================================================
# phpBB Target Languages
# ==============================================================================
#
# Format:
#
#   phpBB_directory|Crowdin_language_ID|Display_name
#
# Base languages and phpBB variants are separate Crowdin targets.
#
# ==============================================================================

PHPBB_LANGUAGES=(
    'en_us|en-US|American English'

    'ar|ar|Arabic'
    'az|az|Azerbaijani'
    'pt_br|pt-BR|Brazilian Portuguese'
    'bg|bg|Bulgarian'
    'ca|ca|Catalan'

    'hr|hr|Croatian'
    'hr_x_vi|hr-x-vi|Croatian (Formal Honorifics)'

    'da|da|Danish'

    'nl|nl|Dutch'
    'nl_x_formal|nl-x-formal|Dutch (Formal Honorifics)'

    'et|et|Estonian'
    'fi|fi|Finnish'
    'fr|fr|French'
    'gd|gd|Gaelic'

    'de|de|German'
    'de_x_sie|de-x-sie|German (Formal Honorifics)'

    'el|el|Greek'
    'he|he|Hebrew'
    'it|it|Italian'
    'ja|ja|Japanese'
    'lt|lt|Lithuanian'

    'zh_cmn_hans|zh-CN|Mandarin Chinese (Simplified Script)'
    'zh_cmn_hant|zh-TW|Mandarin Chinese (Traditional Script)'

    'fa|fa|Persian'
    'pl|pl|Polish'
    'pt|pt-PT|Portuguese (Formal)'
    'ro|ro|Romanian'
    'ru|ru|Russian'

    'sr|sr|Serbian (Cyrillic Script)'
    'sr_x_latin|sr-CS|Serbian (Latin Script)'

    'sk|sk|Slovak'
    'sl|sl|Slovenian'

    'es|es-ES|Spanish'
    'es_x_tu|es-x-tu|Spanish (Casual Honorifics)'

    'tr|tr|Turkish'
    'uk|uk|Ukrainian'
)


# ==============================================================================
# Language Runtime State
# ==============================================================================

declare -A PHPBB_TO_CROWDIN=()
declare -A CROWDIN_TO_PHPBB=()
declare -A LANGUAGE_DISPLAY_NAME=()

PHPBB_LANGUAGE_CODES=()
CROWDIN_TARGET_IDS=()


# ==============================================================================
# Output Helpers
# ==============================================================================

# Print a red "Error: $1" message to stderr.
error()
{
    printf '%bError: %s%b\n' "$RED" "$1" "$NC" >&2
}


# Print a yellow "[!] $1" warning to stdout.
warn()
{
    printf '%b[!] %s%b\n' "$YELLOW" "$1" "$NC"
}


# Print a green "[✓] $1" success message to stdout.
success()
{
    printf '%b[✓] %s%b\n' "$GREEN" "$1" "$NC"
}


# Print a blue "[+] $1" in-progress action message to stdout.
action()
{
    printf '%b[+] %s%b\n' "$BLUE" "$1" "$NC"
}


# Print a section banner: the title ($1) followed by an underline of
# matching length, e.g. for grouping related output under one heading.
section()
{
    local title="$1"
    local separator

    printf '\n%s\n' "$title"

    printf -v separator '%*s' "${#title}" ''

    printf '%s\n' "${separator// /-}"
}


# ==============================================================================
# Usage
# ==============================================================================

usage()
{
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS] [EXTENSION_PATH]

Options:
  -c, --config FILE       Use alternate shared configuration.
  -n, --dry-run           Preview project changes and source upload.
      --download          Download completed translations from Crowdin.
      --download-dry-run  Preview translation download.
  -h, --help              Show help.

Arguments:
  EXTENSION_PATH          phpBB extension directory.
                          Defaults to current directory.

Environment:
  CROWDIN_API_TOKEN       Crowdin Personal Access Token.
  CROWDIN_PROJECT_ID      Optional numeric project ID override.
EOF
}


# ==============================================================================
# Cleanup
# ==============================================================================

# Remove temp files created for this run, if any were created yet.
# Registered as an EXIT trap, so it always runs, including on early
# exits (e.g. --help) before the temp files exist.
cleanup()
{
    [[ -n "$API_RESPONSE_FILE" &&
        -f "$API_RESPONSE_FILE" ]] &&
        rm -f "$API_RESPONSE_FILE"

    [[ -n "$RUNTIME_CROWDIN_CONFIG" &&
        -f "$RUNTIME_CROWDIN_CONFIG" ]] &&
        rm -f "$RUNTIME_CROWDIN_CONFIG"

    # Under `set -e`, the trap's own exit status would otherwise
    # replace the script's real exit status whenever the last check
    # above is false (nothing to remove yet). Force success here so
    # cleanup never masks the actual exit code.
    return 0
}

trap cleanup EXIT


# ==============================================================================
# Helpers
# ==============================================================================

# Strip leading and trailing whitespace from $1 and print the result.
trim()
{
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s' "$value"
}


# If $1 is wrapped in a single matching pair of double or single quotes,
# strip them and print the inner value; otherwise print $1 unchanged.
strip_optional_quotes()
{
    local value="$1"

    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == '"' &&
            "${value: -1}" == '"' ]]; then

            value="${value:1:${#value}-2}"

        elif [[ "${value:0:1}" == "'" &&
            "${value: -1}" == "'" ]]; then

            value="${value:1:${#value}-2}"
        fi
    fi

    printf '%s' "$value"
}


# Parse $1 as a boolean config value (case-insensitive true/yes/on/1 or
# false/no/off/0) and print the canonical 'true' or 'false'. Returns
# non-zero without printing anything if $1 is not a recognized boolean.
normalize_boolean()
{
    local value

    value=$(
        printf '%s' "$1" |
            tr '[:upper:]' '[:lower:]'
    )

    case "$value" in
        true|yes|on|1)
            printf 'true'
            ;;

        false|no|off|0)
            printf 'false'
            ;;

        *)
            return 1
            ;;
    esac
}


# Turn a snake_case/kebab-case identifier ($1) into a human-readable,
# title-cased display name, e.g. "my-extension" -> "My Extension".
# Used as a fallback project name when composer.json has no
# extra.display-name and crowdin.conf sets no PROJECT_NAME.
humanize_identifier()
{
    local identifier="$1"

    printf '%s\n' "$identifier" |
        tr '_-' '  ' |
        awk '
        {
            for (i = 1; i <= NF; i++) {
                $i = toupper(substr($i, 1, 1)) substr($i, 2)
            }

            print
        }
        '
}


# Return success (0) if $1 is present among the remaining arguments,
# failure (1) otherwise.
array_contains()
{
    local wanted="$1"
    shift

    local item

    for item in "$@"; do
        [[ "$item" == "$wanted" ]] && return 0
    done

    return 1
}


# ==============================================================================
# Parse Arguments
# ==============================================================================

POSITIONAL_ARGUMENTS=()

while (($# > 0)); do
    case "$1" in
        -c|--config)
            [[ $# -ge 2 ]] || {
                error "$1 requires a file."
                exit 1
            }

            CONFIG_FILE="$2"
            shift 2
            ;;

        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;

        --download)
            DOWNLOAD_MODE=true
            shift
            ;;

        --download-dry-run)
            DOWNLOAD_MODE=true
            DOWNLOAD_DRY_RUN=true
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        --)
            # Everything after a bare '--' is treated as a positional
            # argument, even if it looks like an option.
            shift

            while (($# > 0)); do
                POSITIONAL_ARGUMENTS+=("$1")
                shift
            done
            ;;

        -*)
            error "Unknown option: $1"
            exit 1
            ;;

        *)
            POSITIONAL_ARGUMENTS+=("$1")
            shift
            ;;
    esac
done

if ((${#POSITIONAL_ARGUMENTS[@]} > 1)); then
    error "Only one extension path may be specified."
    exit 1
fi

if ((${#POSITIONAL_ARGUMENTS[@]} == 1)); then
    EXTENSION_PATH="${POSITIONAL_ARGUMENTS[0]}"
fi

if [[ "$DRY_RUN" == "true" &&
    "$DOWNLOAD_MODE" == "true" ]]; then

    error "--dry-run cannot be combined with --download."

    printf '%s\n' \
        "Use --download-dry-run to preview translation downloads." >&2

    exit 1
fi


# ==============================================================================
# Dependencies
# ==============================================================================

for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        error "'$command_name' is required."
        exit 1
    }
done


# ==============================================================================
# Resolve Extension
# ==============================================================================

[[ -d "$EXTENSION_PATH" ]] || {
    error "Extension directory not found: $EXTENSION_PATH"
    exit 1
}

EXTENSION_ROOT=$(
    cd -- "$EXTENSION_PATH" &&
        pwd
)

if command -v git >/dev/null 2>&1 &&
    git -C "$EXTENSION_ROOT" \
        rev-parse --show-toplevel >/dev/null 2>&1; then

    GIT_ROOT=$(
        git -C "$EXTENSION_ROOT" \
            rev-parse --show-toplevel
    )

    # If EXTENSION_PATH points into a subdirectory of a git repo whose
    # top level has composer.json, use that top level as the extension
    # root instead, so paths in the generated crowdin.yml stay relative
    # to the repository root.
    if [[ -f "$GIT_ROOT/composer.json" ]]; then
        EXTENSION_ROOT="$GIT_ROOT"
    fi
fi

COMPOSER_FILE="$EXTENSION_ROOT/composer.json"


# ==============================================================================
# Read Configuration
# ==============================================================================

section "Configuration"

if [[ -f "$CONFIG_FILE" ]]; then
    success "Using shared configuration: $CONFIG_FILE"

    # Read the config as simple KEY=value lines. Blank lines and lines
    # starting with '#' are skipped; the trailing `|| [[ -n "$line" ]]`
    # ensures a final line without a trailing newline is still read.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(trim "$line")

        [[ -n "$line" ]] || continue
        [[ "$line" != \#* ]] || continue

        [[ "$line" == *=* ]] || {
            error "Invalid configuration line: $line"
            exit 1
        }

        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        value=$(strip_optional_quotes "$value")

        case "$key" in
            PROJECT_NAME)
                PROJECT_NAME="$value"
                CONFIG_SET_PROJECT_NAME=true
                ;;

            PROJECT_IDENTIFIER)
                PROJECT_IDENTIFIER="$value"
                ;;

            PROJECT_DESCRIPTION)
                PROJECT_DESCRIPTION="$value"
                CONFIG_SET_PROJECT_DESCRIPTION=true
                ;;

            SOURCE_LANGUAGE)
                SOURCE_LANGUAGE="$value"
                ;;

            PROJECT_VISIBILITY)
                PROJECT_VISIBILITY="$value"
                CONFIG_SET_PROJECT_VISIBILITY=true
                ;;

            LANGUAGE_ACCESS_POLICY)
                LANGUAGE_ACCESS_POLICY="$value"
                CONFIG_SET_LANGUAGE_ACCESS_POLICY=true
                ;;

            SOURCE_SYNC)
                SOURCE_SYNC=$(normalize_boolean "$value") || {
                    error "Invalid SOURCE_SYNC value: $value"
                    exit 1
                }
                ;;

            CROWDIN_CLI_TEMPLATE)
                if [[ "$value" = /* ]]; then
                    CROWDIN_CLI_TEMPLATE="$value"
                else
                    CROWDIN_CLI_TEMPLATE="$SCRIPT_DIR/$value"
                fi
                ;;

            *)
                error "Unknown configuration option: $key"
                exit 1
                ;;
        esac
    done < "$CONFIG_FILE"
else
    warn "No crowdin.conf found. Using defaults."
fi

[[ "$SOURCE_LANGUAGE" == "en" ]] || {
    error "phpBB source language must be 'en'."
    exit 1
}

if [[ "$SOURCE_SYNC" == "true" ||
    "$DOWNLOAD_MODE" == "true" ]]; then

    [[ -f "$CROWDIN_CLI_TEMPLATE" ]] || {
        error "Crowdin template not found: $CROWDIN_CLI_TEMPLATE"
        exit 1
    }

    command -v crowdin >/dev/null 2>&1 || {
        error "Crowdin CLI was not found."
        exit 1
    }
fi

printf '%-24s %s\n' "Tools directory:" "$SCRIPT_DIR"
printf '%-24s %s\n' "Extension directory:" "$EXTENSION_ROOT"


# ==============================================================================
# Composer Identity
# ==============================================================================

section "Extension Identity"

[[ -f "$COMPOSER_FILE" ]] || {
    error "composer.json not found."
    exit 1
}

jq -e . "$COMPOSER_FILE" >/dev/null 2>&1 || {
    error "composer.json contains invalid JSON."
    exit 1
}

COMPOSER_PACKAGE=$(jq -r '.name // empty' "$COMPOSER_FILE")
COMPOSER_DESCRIPTION=$(jq -r '.description // empty' "$COMPOSER_FILE")
COMPOSER_TYPE=$(jq -r '.type // empty' "$COMPOSER_FILE")

COMPOSER_DISPLAY_NAME=$(
    jq -r '.extra["display-name"] // empty' "$COMPOSER_FILE"
)

[[ "$COMPOSER_PACKAGE" == */* ]] || {
    error "composer.json name must use vendor/package format."
    exit 1
}

COMPOSER_VENDOR="${COMPOSER_PACKAGE%%/*}"
COMPOSER_IDENTIFIER="${COMPOSER_PACKAGE#*/}"

if [[ -n "$COMPOSER_TYPE" &&
    "$COMPOSER_TYPE" != "phpbb-extension" ]]; then

    warn "composer.json type is '$COMPOSER_TYPE', not 'phpbb-extension'."
fi

[[ -n "$PROJECT_IDENTIFIER" ]] ||
    PROJECT_IDENTIFIER="$COMPOSER_IDENTIFIER"

if [[ -z "$PROJECT_NAME" ]]; then
    if [[ -n "$COMPOSER_DISPLAY_NAME" ]]; then
        PROJECT_NAME="$COMPOSER_DISPLAY_NAME"
    else
        PROJECT_NAME=$(humanize_identifier "$PROJECT_IDENTIFIER")
    fi
fi

[[ -n "$PROJECT_DESCRIPTION" ]] ||
    PROJECT_DESCRIPTION="$COMPOSER_DESCRIPTION"

printf '%-24s %s\n' "Composer package:" "$COMPOSER_PACKAGE"
printf '%-24s %s\n' "Composer vendor:" "$COMPOSER_VENDOR"
printf '%-24s %s\n' "Project identifier:" "$PROJECT_IDENTIFIER"
printf '%-24s %s\n' "Project name:" "$PROJECT_NAME"
printf '%-24s %s\n' "Source language:" "$SOURCE_LANGUAGE"


# ==============================================================================
# Credentials
# ==============================================================================

[[ -n "$CROWDIN_API_TOKEN" ]] || {
    error "CROWDIN_API_TOKEN is not set."
    exit 1
}


# ==============================================================================
# Temporary Files
# ==============================================================================

API_RESPONSE_FILE=$(mktemp)
RUNTIME_CROWDIN_CONFIG=$(mktemp)


# ==============================================================================
# API Helper
# ==============================================================================

# Issue an authenticated Crowdin API v2 request.
#
# Arguments:
#   $1 - HTTP method (GET, POST, PATCH, ...)
#   $2 - API path, relative to $CROWDIN_API_BASE (e.g. "/projects")
#   $3 - optional JSON request body
#
# Side effects:
#   Writes the raw response body to $API_RESPONSE_FILE and the HTTP
#   status code to $HTTP_STATUS. Does not itself treat a non-2xx status
#   as fatal; callers check $HTTP_STATUS/report_api_error as needed.
api_request()
{
    local method="$1"
    local path="$2"
    local body="${3:-}"

    local -a args

    : > "$API_RESPONSE_FILE"

    args=(
        --silent
        --show-error
        --connect-timeout 10
        --max-time 30
        --output "$API_RESPONSE_FILE"
        --write-out '%{http_code}'
        --request "$method"
        --header "Authorization: Bearer $CROWDIN_API_TOKEN"
        --header "Accept: application/json"
    )

    if [[ -n "$body" ]]; then
        args+=(
            --header "Content-Type: application/json"
            --data "$body"
        )
    fi

    HTTP_STATUS=$(
        curl "${args[@]}" "$CROWDIN_API_BASE$path"
    )
}


# Print an error message ($1) annotated with the last $HTTP_STATUS, and
# dump the last Crowdin API response body (pretty-printed if it is
# JSON) to stderr for diagnosis. Expects api_request() to have run first.
report_api_error()
{
    error "$1 (HTTP $HTTP_STATUS)."

    if [[ -s "$API_RESPONSE_FILE" ]]; then
        printf '\nCrowdin response:\n' >&2

        jq . "$API_RESPONSE_FILE" >&2 2>/dev/null ||
            cat "$API_RESPONSE_FILE" >&2
    fi
}


# ==============================================================================
# Custom Crowdin Languages
# ==============================================================================

# Idempotently ensure one custom Crowdin language variant exists,
# creating it if necessary by cloning plural categories and text
# direction from its base dialect.
#
# Arguments:
#   $1 - custom Crowdin language ID (e.g. "de-x-sie")
#   $2 - display name (e.g. "German (Formal Honorifics)")
#   $3 - base language it is a dialect of (e.g. "de")
#   $4 - three-letter language code required by the Crowdin API
#
# Returns non-zero (without creating anything) if the language already
# exists under a different dialectOf, if the API lookup/creation fails,
# or if --download is active and the language is missing.
ensure_custom_language()
{
    local custom_id="$1"
    local custom_name="$2"
    local dialect_of="$3"
    local three_letters="$4"

    local dialect_data
    local plural_categories
    local text_direction
    local body

    api_request GET "/languages/$custom_id"

    if [[ "$HTTP_STATUS" == "200" ]]; then
        local existing_name
        local existing_dialect

        existing_name=$(
            jq -r '.data.name // empty' "$API_RESPONSE_FILE"
        )

        existing_dialect=$(
            jq -r '.data.dialectOf // empty' "$API_RESPONSE_FILE"
        )

        [[ "$existing_dialect" == "$dialect_of" ]] || {
            error \
                "Custom language '$custom_id' exists but dialectOf is '$existing_dialect', expected '$dialect_of'."
            return 1
        }

        success "$existing_name already exists."
        return 0
    fi

    if [[ "$HTTP_STATUS" != "404" ]]; then
        report_api_error \
            "Failed to check custom language '$custom_id'"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        action \
            "Would create custom language '$custom_name' ($custom_id)."
        return 0
    fi

    if [[ "$DOWNLOAD_MODE" == "true" ]]; then
        error \
            "Required custom language '$custom_id' does not exist."
        error \
            "Run crowdin-init.sh without --download first."
        return 1
    fi

    # Custom languages must be created with valid plural categories and
    # text direction, so borrow them from the base dialect rather than
    # guessing.
    api_request GET "/languages/$dialect_of"

    [[ "$HTTP_STATUS" == "200" ]] || {
        report_api_error \
            "Unable to retrieve dialect base '$dialect_of'"
        return 1
    }

    dialect_data=$(jq -c '.data' "$API_RESPONSE_FILE")

    plural_categories=$(
        jq -c '.pluralCategoryNames' <<< "$dialect_data"
    )

    text_direction=$(
        jq -r '.textDirection // "ltr"' <<< "$dialect_data"
    )

    body=$(
        jq -n \
            --arg name "$custom_name" \
            --arg code "$custom_id" \
            --arg locale "$custom_id" \
            --arg three_letters "$three_letters" \
            --arg text_direction "$text_direction" \
            --arg dialect "$dialect_of" \
            --argjson plural_categories "$plural_categories" \
            '
            {
                name: $name,
                code: $code,
                localeCode: $locale,
                threeLettersCode: $three_letters,
                textDirection: $text_direction,
                pluralCategoryNames: $plural_categories,
                dialectOf: $dialect
            }
            '
    )

    action \
        "Creating custom language '$custom_name'..."

    api_request POST "/languages" "$body"

    [[ "$HTTP_STATUS" == "201" ]] || {
        report_api_error \
            "Failed to create custom language '$custom_name'"
        return 1
    }

    local created_id

    created_id=$(
        jq -r '.data.id // empty' "$API_RESPONSE_FILE"
    )

    [[ "$created_id" == "$custom_id" ]] || {
        error \
            "Crowdin created unexpected language ID '$created_id'; expected '$custom_id'."
        return 1
    }

    success \
        "Created custom language '$custom_name' ($custom_id)."
}


section "Custom Crowdin Languages"

for record in "${CUSTOM_LANGUAGES[@]}"; do
    IFS='|' read -r \
        custom_id \
        custom_name \
        dialect_of \
        three_letters \
        <<< "$record"

    ensure_custom_language \
        "$custom_id" \
        "$custom_name" \
        "$dialect_of" \
        "$three_letters" || exit 1
done


# ==============================================================================
# Validate Crowdin Languages
# ==============================================================================

section "phpBB Languages"

printf '%-22s %-20s %s\n' \
    "phpBB directory" \
    "Crowdin ID" \
    "Language"

printf '%-22s %-20s %s\n' \
    "----------------------" \
    "--------------------" \
    "--------"

for record in "${PHPBB_LANGUAGES[@]}"; do
    IFS='|' read -r \
        phpbb_code \
        crowdin_id \
        display_name \
        <<< "$record"

    api_request GET "/languages/$crowdin_id"

    if [[ "$HTTP_STATUS" == "404" &&
        "$DRY_RUN" == "true" ]]; then

        printf '%-22s %-20s %s %s\n' \
            "$phpbb_code" \
            "$crowdin_id" \
            "$display_name" \
            "(would be created)"

    elif [[ "$HTTP_STATUS" == "200" ]]; then
        printf '%-22s %-20s %s\n' \
            "$phpbb_code" \
            "$crowdin_id" \
            "$display_name"

    else
        report_api_error \
            "Invalid Crowdin language ID '$crowdin_id'"
        exit 1
    fi

    # Two phpBB directories mapping to the same Crowdin language ID
    # would make the language <-> directory mapping ambiguous later
    # (e.g. when building the CLI config and when downloading files).
    if [[ -n "${CROWDIN_TO_PHPBB[$crowdin_id]:-}" ]]; then
        error \
            "Crowdin language '$crowdin_id' maps to more than one phpBB directory."
        exit 1
    fi

    PHPBB_TO_CROWDIN["$phpbb_code"]="$crowdin_id"
    CROWDIN_TO_PHPBB["$crowdin_id"]="$phpbb_code"
    LANGUAGE_DISPLAY_NAME["$crowdin_id"]="$display_name"

    PHPBB_LANGUAGE_CODES+=("$phpbb_code")
    CROWDIN_TARGET_IDS+=("$crowdin_id")
done


# ==============================================================================
# Variant Status
# ==============================================================================

section "phpBB Variant Targets"

printf '%-26s %-16s %s\n' \
    "phpBB directory" \
    "Crowdin target" \
    "Relationship"

printf '%-26s %-16s %s\n' \
    "--------------------------" \
    "----------------" \
    "------------"

printf '%-26s %-16s %s\n' \
    "de" \
    "de" \
    "German"

printf '%-26s %-16s %s\n' \
    "de_x_sie" \
    "de-x-sie" \
    "German formal dialect"

printf '%-26s %-16s %s\n' \
    "es" \
    "es-ES" \
    "Spanish"

printf '%-26s %-16s %s\n' \
    "es_x_tu" \
    "es-x-tu" \
    "Spanish casual dialect"

printf '%-26s %-16s %s\n' \
    "nl" \
    "nl" \
    "Dutch"

printf '%-26s %-16s %s\n' \
    "nl_x_formal" \
    "nl-x-formal" \
    "Dutch formal dialect"

printf '%-26s %-16s %s\n' \
    "hr" \
    "hr" \
    "Croatian"

printf '%-26s %-16s %s\n' \
    "hr_x_vi" \
    "hr-x-vi" \
    "Croatian formal dialect"

success \
    "Base languages and phpBB variants are independent Crowdin targets."


# ==============================================================================
# Locate Existing Project
# ==============================================================================

section "Crowdin Project"

if [[ -n "$CROWDIN_PROJECT_ID" ]]; then
    PROJECT_ID="$CROWDIN_PROJECT_ID"

    api_request GET "/projects/$PROJECT_ID"

    [[ "$HTTP_STATUS" =~ ^2 ]] || {
        report_api_error "Failed to retrieve project"
        exit 1
    }

    CURRENT_PROJECT=$(jq -c '.data' "$API_RESPONSE_FILE")

    CURRENT_IDENTIFIER=$(
        jq -r '.identifier // empty' <<< "$CURRENT_PROJECT"
    )

    if [[ -n "$CURRENT_IDENTIFIER" &&
        "$CURRENT_IDENTIFIER" != "$PROJECT_IDENTIFIER" ]]; then

        warn \
            "CROWDIN_PROJECT_ID identifies '$CURRENT_IDENTIFIER', expected '$PROJECT_IDENTIFIER'."
    fi
else
    # No explicit project ID: page through every project on the
    # account looking for one whose identifier matches
    # $PROJECT_IDENTIFIER, since the Crowdin API has no "get by
    # identifier" endpoint.
    offset=0
    limit=100

    while :; do
        api_request \
            GET \
            "/projects?limit=$limit&offset=$offset"

        [[ "$HTTP_STATUS" =~ ^2 ]] || {
            report_api_error "Failed to list projects"
            exit 1
        }

        CURRENT_PROJECT=$(
            jq -c \
                --arg identifier "$PROJECT_IDENTIFIER" \
                '
                [
                    .data[]?.data
                    | select(.identifier == $identifier)
                ][0] // empty
                ' \
                "$API_RESPONSE_FILE"
        )

        if [[ -n "$CURRENT_PROJECT" ]]; then
            PROJECT_ID=$(jq -r '.id' <<< "$CURRENT_PROJECT")
            break
        fi

        total_count=$(
            jq -r '.pagination.totalCount // 0' \
                "$API_RESPONSE_FILE"
        )

        offset=$((offset + limit))

        ((offset < total_count)) || break
    done
fi


# ==============================================================================
# Create Project
# ==============================================================================

if [[ -z "$PROJECT_ID" ]]; then
    warn "Crowdin project does not exist."

    if [[ "$DRY_RUN" == "true" ]]; then
        action "Would create project '$PROJECT_NAME'."

        printf '%-24s %d\n' \
            "Target languages:" \
            "${#CROWDIN_TARGET_IDS[@]}"

        exit 0
    fi

    if [[ "$DOWNLOAD_MODE" == "true" ]]; then
        error \
            "Cannot download translations because the Crowdin project does not exist."
        exit 1
    fi

    TARGET_LANGUAGES_JSON=$(
        printf '%s\n' "${CROWDIN_TARGET_IDS[@]}" |
            jq -R . |
            jq -s .
    )

    CREATE_BODY=$(
        jq -n \
            --arg name "$PROJECT_NAME" \
            --arg identifier "$PROJECT_IDENTIFIER" \
            --arg source "$SOURCE_LANGUAGE" \
            --arg visibility "$PROJECT_VISIBILITY" \
            --arg access "$LANGUAGE_ACCESS_POLICY" \
            --arg description "$PROJECT_DESCRIPTION" \
            --argjson targets "$TARGET_LANGUAGES_JSON" \
            '
            {
                name: $name,
                identifier: $identifier,
                sourceLanguageId: $source,
                targetLanguageIds: $targets,
                visibility: $visibility,
                languageAccessPolicy: $access
            }
            +
            if $description != "" then
                {description: $description}
            else
                {}
            end
            '
    )

    action "Creating Crowdin project..."

    api_request POST "/projects" "$CREATE_BODY"

    [[ "$HTTP_STATUS" =~ ^2 ]] || {
        report_api_error "Failed to create Crowdin project"
        exit 1
    }

    CURRENT_PROJECT=$(jq -c '.data' "$API_RESPONSE_FILE")
    PROJECT_ID=$(jq -r '.id' <<< "$CURRENT_PROJECT")

    success "Created Crowdin project."
else
    success "Project exists."
fi


# ==============================================================================
# Refresh Project
# ==============================================================================

api_request GET "/projects/$PROJECT_ID"

[[ "$HTTP_STATUS" =~ ^2 ]] || {
    report_api_error "Failed to refresh Crowdin project"
    exit 1
}

CURRENT_PROJECT=$(jq -c '.data' "$API_RESPONSE_FILE")


# ==============================================================================
# Validate Source Language
# ==============================================================================

CURRENT_SOURCE_LANGUAGE=$(
    jq -r '.sourceLanguageId // empty' \
        <<< "$CURRENT_PROJECT"
)

[[ "$CURRENT_SOURCE_LANGUAGE" == "$SOURCE_LANGUAGE" ]] || {
    error \
        "Crowdin source language is '$CURRENT_SOURCE_LANGUAGE', expected '$SOURCE_LANGUAGE'."
    exit 1
}


# ==============================================================================
# Reconcile Explicit Project Settings
# ==============================================================================

section "Project Configuration"

# Only settings explicitly present in crowdin.conf (CONFIG_SET_* flags)
# are reconciled, and only when they differ from the live project, so
# that unset options never overwrite values already configured in
# Crowdin. Each change is queued as an RFC 6902 JSON Patch operation and
# applied together in a single PATCH request below.
PROJECT_PATCH_OPERATIONS=()

CURRENT_NAME=$(jq -r '.name // ""' <<< "$CURRENT_PROJECT")

CURRENT_DESCRIPTION=$(
    jq -r '.description // ""' <<< "$CURRENT_PROJECT"
)

CURRENT_VISIBILITY=$(
    jq -r '.visibility // ""' <<< "$CURRENT_PROJECT"
)

CURRENT_ACCESS_POLICY=$(
    jq -r '.languageAccessPolicy // ""' <<< "$CURRENT_PROJECT"
)

if [[ "$CONFIG_SET_PROJECT_NAME" == "true" &&
    "$CURRENT_NAME" != "$PROJECT_NAME" ]]; then

    PROJECT_PATCH_OPERATIONS+=(
        "$(
            jq -nc \
                --arg value "$PROJECT_NAME" \
                '{op:"replace",path:"/name",value:$value}'
        )"
    )
fi

if [[ "$CONFIG_SET_PROJECT_DESCRIPTION" == "true" &&
    "$CURRENT_DESCRIPTION" != "$PROJECT_DESCRIPTION" ]]; then

    PROJECT_PATCH_OPERATIONS+=(
        "$(
            jq -nc \
                --arg value "$PROJECT_DESCRIPTION" \
                '{op:"replace",path:"/description",value:$value}'
        )"
    )
fi

if [[ "$CONFIG_SET_PROJECT_VISIBILITY" == "true" &&
    "$CURRENT_VISIBILITY" != "$PROJECT_VISIBILITY" ]]; then

    PROJECT_PATCH_OPERATIONS+=(
        "$(
            jq -nc \
                --arg value "$PROJECT_VISIBILITY" \
                '{op:"replace",path:"/visibility",value:$value}'
        )"
    )
fi

if [[ "$CONFIG_SET_LANGUAGE_ACCESS_POLICY" == "true" &&
    "$CURRENT_ACCESS_POLICY" != "$LANGUAGE_ACCESS_POLICY" ]]; then

    PROJECT_PATCH_OPERATIONS+=(
        "$(
            jq -nc \
                --arg value "$LANGUAGE_ACCESS_POLICY" \
                '{op:"replace",path:"/languageAccessPolicy",value:$value}'
        )"
    )
fi

if ((${#PROJECT_PATCH_OPERATIONS[@]} > 0)); then
    PATCH_BODY=$(
        printf '%s\n' "${PROJECT_PATCH_OPERATIONS[@]}" |
            jq -s .
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        action \
            "Would update ${#PROJECT_PATCH_OPERATIONS[@]} project setting(s)."

    elif [[ "$DOWNLOAD_MODE" == "true" ]]; then
        warn \
            "Project settings differ, but download mode does not modify them."

    else
        action "Updating project configuration..."

        api_request \
            PATCH \
            "/projects/$PROJECT_ID" \
            "$PATCH_BODY"

        [[ "$HTTP_STATUS" =~ ^2 ]] || {
            report_api_error \
                "Failed to update project configuration"
            exit 1
        }

        success "Project configuration updated."
    fi
else
    success "No project configuration changes were required."
fi


# ==============================================================================
# Reconcile Target Languages
# ==============================================================================

section "Target Language Status"

mapfile -t CURRENT_LANGUAGES < <(
    jq -r \
        '.targetLanguageIds // [] | .[]' \
        <<< "$CURRENT_PROJECT"
)

declare -A CURRENT_LANGUAGE_SET=()

for language_id in "${CURRENT_LANGUAGES[@]}"; do
    CURRENT_LANGUAGE_SET["$language_id"]=1
done

# Target languages present in PHPBB_LANGUAGES but missing from the live
# project; these will be added below.
LANGUAGES_TO_ADD=()

for language_id in "${CROWDIN_TARGET_IDS[@]}"; do
    if [[ -z "${CURRENT_LANGUAGE_SET[$language_id]:-}" ]]; then
        LANGUAGES_TO_ADD+=("$language_id")
    fi
done

# Target languages present on Crowdin but not in PHPBB_LANGUAGES.
# These are reported but deliberately left untouched (never removed),
# in case they were added manually or by another tool.
EXTRA_LANGUAGES=()

for language_id in "${CURRENT_LANGUAGES[@]}"; do
    if ! array_contains \
        "$language_id" \
        "${CROWDIN_TARGET_IDS[@]}"; then

        EXTRA_LANGUAGES+=("$language_id")
    fi
done

printf '%-24s %d\n' \
    "Required targets:" \
    "${#CROWDIN_TARGET_IDS[@]}"

printf '%-24s %d\n' \
    "Current targets:" \
    "${#CURRENT_LANGUAGES[@]}"

printf '%-24s %d\n' \
    "Missing targets:" \
    "${#LANGUAGES_TO_ADD[@]}"

if ((${#LANGUAGES_TO_ADD[@]} > 0)); then
    printf '\nMissing targets:\n'

    for language_id in "${LANGUAGES_TO_ADD[@]}"; do
        printf '  + %-18s %s\n' \
            "$language_id" \
            "${LANGUAGE_DISPLAY_NAME[$language_id]:-}"
    done
fi

if ((${#EXTRA_LANGUAGES[@]} > 0)); then
    printf '\nAdditional Crowdin targets:\n'

    for language_id in "${EXTRA_LANGUAGES[@]}"; do
        printf '  ! %s (preserved)\n' "$language_id"
    done
fi

if ((${#LANGUAGES_TO_ADD[@]} > 0)); then
    if [[ "$DRY_RUN" == "true" ]]; then
        action \
            "Would add ${#LANGUAGES_TO_ADD[@]} target language(s)."

    elif [[ "$DOWNLOAD_MODE" == "true" ]]; then
        warn \
            "${#LANGUAGES_TO_ADD[@]} required target language(s) are missing."

        warn \
            "Download mode will not change the Crowdin project."

    else
        # The Crowdin API replaces the entire targetLanguageIds list on
        # PATCH rather than appending, so the current languages must be
        # resent alongside the new ones or they would be dropped.
        ALL_LANGUAGES=(
            "${CURRENT_LANGUAGES[@]}"
            "${LANGUAGES_TO_ADD[@]}"
        )

        ALL_LANGUAGES_JSON=$(
            printf '%s\n' "${ALL_LANGUAGES[@]}" |
                jq -R . |
                jq -s .
        )

        PATCH_BODY=$(
            jq -n \
                --argjson languages "$ALL_LANGUAGES_JSON" \
                '[
                    {
                        op: "replace",
                        path: "/targetLanguageIds",
                        value: $languages
                    }
                ]'
        )

        action "Adding missing target languages..."

        api_request \
            PATCH \
            "/projects/$PROJECT_ID" \
            "$PATCH_BODY"

        [[ "$HTTP_STATUS" =~ ^2 ]] || {
            report_api_error \
                "Failed to add target languages"
            exit 1
        }

        success "Target languages updated."
    fi
else
    success \
        "All required Crowdin target languages are present."
fi


# ==============================================================================
# Build Runtime CLI Config
# ==============================================================================

# Render $CROWDIN_CLI_TEMPLATE into $RUNTIME_CROWDIN_CONFIG, replacing
# the literal placeholder line '__PHPBB_LANGUAGE_MAPPING__' with a YAML
# mapping block of every "'crowdin-id': 'phpbb_directory'" pair, so the
# Crowdin CLI knows which phpBB language directory each Crowdin target
# language's downloaded translations belong in.
build_runtime_crowdin_config()
{
    local mapping_file
    local phpbb_code
    local crowdin_id

    mapping_file=$(mktemp)

    for phpbb_code in "${PHPBB_LANGUAGE_CODES[@]}"; do
        crowdin_id="${PHPBB_TO_CROWDIN[$phpbb_code]}"

        printf "        '%s': '%s'\n" \
            "$crowdin_id" \
            "$phpbb_code" \
            >> "$mapping_file"
    done

    grep -q \
        '^__PHPBB_LANGUAGE_MAPPING__$' \
        "$CROWDIN_CLI_TEMPLATE" || {
        rm -f "$mapping_file"

        error \
            "Template is missing __PHPBB_LANGUAGE_MAPPING__."

        return 1
    }

    # Splice the generated mapping lines in place of the placeholder,
    # preserving every other template line unchanged.
    awk \
        -v mapping_file="$mapping_file" \
        '
        /^__PHPBB_LANGUAGE_MAPPING__$/ {
            while ((getline line < mapping_file) > 0) {
                print line
            }

            close(mapping_file)
            next
        }

        {
            print
        }
        ' \
        "$CROWDIN_CLI_TEMPLATE" \
        > "$RUNTIME_CROWDIN_CONFIG"

    rm -f "$mapping_file"
}


# ==============================================================================
# Crowdin CLI Environment
# ==============================================================================

# Export the environment variables the Crowdin CLI reads, generate the
# runtime crowdin.yml (see build_runtime_crowdin_config), and lint it
# before it is used for an upload or download. Exits non-zero on lint
# failure, without leaving the CLI to fail later on a bad config.
prepare_crowdin_cli()
{
    export CROWDIN_PERSONAL_TOKEN="$CROWDIN_API_TOKEN"
    export CROWDIN_PROJECT_ID="$PROJECT_ID"
    export CROWDIN_BASE_PATH="$EXTENSION_ROOT"

    build_runtime_crowdin_config || return 1

    action "Validating Crowdin configuration..."

    crowdin config lint \
        --config "$RUNTIME_CROWDIN_CONFIG" \
        --no-colors \
        --no-progress || {
        error "Crowdin configuration validation failed."
        return 1
    }

    success "Crowdin configuration is valid."
}


# ==============================================================================
# Translation Download
# ==============================================================================

if [[ "$DOWNLOAD_MODE" == "true" ]]; then
    section "Translations"

    prepare_crowdin_cli || exit 1

    if [[ "$DOWNLOAD_DRY_RUN" == "true" ]]; then
        action \
            "Previewing completed translation download..."

        crowdin download translations \
            --config "$RUNTIME_CROWDIN_CONFIG" \
            --skip-untranslated-files \
            --dryrun \
            --no-colors \
            --no-progress || {
            error \
                "Crowdin translation download dry-run failed."
            exit 1
        }

        success \
            "Translation download dry-run completed."
    else
        action "Downloading completed translations..."

        crowdin download translations \
            --config "$RUNTIME_CROWDIN_CONFIG" \
            --skip-untranslated-files \
            --no-colors \
            --no-progress || {
            error "Crowdin translation download failed."
            exit 1
        }

        success "Translation download completed."
    fi


# ==============================================================================
# Source Upload
# ==============================================================================

else
    section "Source Files"

    if [[ "$SOURCE_SYNC" == "true" ]]; then
        prepare_crowdin_cli || exit 1

        if [[ "$DRY_RUN" == "true" ]]; then
            action "Testing source synchronization..."

            crowdin upload sources \
                --config "$RUNTIME_CROWDIN_CONFIG" \
                --dryrun \
                --no-colors \
                --no-progress || {
                error "Crowdin source dry-run failed."
                exit 1
            }

            success "Crowdin source dry-run completed."
        else
            action "Synchronizing source files..."

            crowdin upload sources \
                --config "$RUNTIME_CROWDIN_CONFIG" \
                --no-colors \
                --no-progress || {
                error \
                    "Crowdin source synchronization failed."
                exit 1
            }

            success "Source synchronization completed."
        fi
    else
        printf '%-24s %s\n' \
            "Source sync:" \
            "Disabled"
    fi
fi


# ==============================================================================
# Final State
# ==============================================================================

section "Status"

printf '%-24s %s\n' \
    "Project ID:" \
    "$PROJECT_ID"

printf '%-24s %s\n' \
    "Project name:" \
    "$PROJECT_NAME"

printf '%-24s %s\n' \
    "Identifier:" \
    "$PROJECT_IDENTIFIER"

printf '%-24s %d\n' \
    "Crowdin targets:" \
    "${#CROWDIN_TARGET_IDS[@]}"

printf '%-24s %d\n' \
    "Custom variants:" \
    "${#CUSTOM_LANGUAGES[@]}"

if [[ "$DOWNLOAD_MODE" == "true" ]]; then
    if [[ "$DOWNLOAD_DRY_RUN" == "true" ]]; then
        success \
            "Crowdin translation download preview complete."
    else
        success \
            "Crowdin translation download complete."
    fi
else
    success "Crowdin project synchronization complete."
fi
