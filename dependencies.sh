#!/bin/bash

# ------------------------------------------------------------------- #
# ----- Helper variables -------------------------------------------- #
# ------------------------------------------------------------------- #


# Regex pattern for maven dependency strings
#  Should be at least <Group ID>:<Artifact ID>:<Version>:provided:<MD5 Hash> 
#  but can contain more fields before the 'provided:<MD5-Sum>' at the end
pattern='^([a-zA-Z0-9_\-\.]+:){3,}provided:[a-z0-9]{32}$'

# ------------------------------------------------------------------- #
# ----- Helper functions -------------------------------------------- #
# ------------------------------------------------------------------- #
showHelp() {
    echo -e "\n ----- $(basename $0) -----"
    echo "    A script to determine the transitive dependencies of a maven project "
    echo "    and check which of them are already deployed to your Liferay instance."
    echo
    echo "  Usage: ./$(basename $0) [-c /path/to/conf] [-s] /path/to/maven-project/1 /path/to/maven-project/2 ..."
    echo "         ./$(basename $0) [-c /path/to/conf] [-ar] Maven:Dependency:String:1.0.0:MD5Sum Maven:Dependency:String:2.0.0:MD5Sum ..."
    echo
    echo -e "  Help: ./$(basename $0) [-h|-?]\n"

    exit 2
}

# Checks if the first argument of this function is an existing local directory 
# and if the directory contains a pom.xml file on the first level.
#
# Returns: 1 if not a valid directory or pom.xml is missing, 0 else
isValidMavenDirectory() {
    path=$1

    if [[ ! -d "$path" ]]; then
        echo "${bold}${red}$path is no valid path to a directory and will be ignored.${normal}"
        return 1
    fi
    
    # Look for pom.xml file in the given directory
    pom=$(find ${path} -maxdepth 1 -type f -name "pom.xml" | wc -l)

    if [[ ${pom} == 0 ]]; then
        echo "${bold}${red}$path is not a Maven project because it does not contain a pom.xml file. Path will be ignored.${normal}"
        return 1
    fi
}

# Checks if the first argument of this function matches the pattern of a Maven dependency string.
#
# Returns: 0 if string matches, 1 else
isValidMavenDependency() {
    dependency=$1

    # Check if dependency String matches maven dependency string pattern
    if [[ ! ${dependency} =~ $pattern ]]; then
        echo "${red}${dependency} does not maven match dependency string format. Will be ignored.${normal}"
        return 1
    fi
}

showDependencies() {
    path=$1

    # Project name as last part of the path
    project=$(basename ${path})

    # List all transitive dependencies with Maven that are declared as provided
    (cd ${path} && mvn -q dependency:list -DoutputFile=/tmp/dep-list-${project} -DincludeScope=provided)
    (cd ${path} && mvn -q dependency:tree -DoutputFile=/tmp/dep-tree-${project} -DincludeScope=provided)

    # Remove all lines from list output file that are not dependencies
    sed -i '/^   /!d' /tmp/dep-list-${project}
    # Trim whitespaces at start and end of line
    sed -i 's/^ *//;s/ *$//' /tmp/dep-list-${project}

    # Add MD5-Sum to all dependencies and check against already deployed dependencies
    while read line ; do
        md5=$(echo -n $line | md5sum | cut -f 1 -d ' ')
        sed -i "/$line/s/$/:${md5}/" /tmp/dep-list-${project}
        sed -i "/$line/s/$/:${md5}/" /tmp/dep-tree-${project}

        if grep -Fq "$md5" ${local_file_path}
        then
            sed -i "/$line/s/$/${included}/" /tmp/dep-list-${project}
            sed -i "/$line/s/$/${included}/" /tmp/dep-tree-${project}
        fi
    done < /tmp/dep-list-${project}

    # Print list and tree in terminal
    echo -e "\n    ${smul}${bold}All needed dependencies of project: ${project}${normal}\n"

    awk -F":" 'BEGIN{ print "\033[1mGroup-ID:Artifact-ID:Type:Version:Scope:MD5-Sum\033[0m\n" } 
                    $4 ~ /sources/ { next }
                    { print $1 ":" $2 ":" $3 ":" $4 ":" $5 ":" $6 | "sort" }' /tmp/dep-list-${project} | column -t -s ":"

    echo -e "\n\n    ${smul}${bold}Dependencies that still have to be deployed:${normal}\n"

    grep -v "Already deployed" /tmp/dep-tree-${project} | grep -v ":sources:"
}

# Copies the remote file with the deployed dependencies to a local directory 
#  which is specified in the config file of this script.
#
# Exits the script with error code 1 if the file with the deployed dependencies cannot be fetched.
fetchDeployedDependencies() {
    echo -n "Loading already deployed dependencies ..."
    scp -q -i ${HOME}/.ssh/${ssh_key} ${ssh_user}@${ssh_host}:${remote_file_path} ${local_file_path}

    if [[ $? -ne 0 ]]; then
        echo -e " ${bold}${red}Fetching of deployed dependencies failed.${normal}"
        exit 1
    else 
        echo -e " ${green}${bold}Done${normal}"
    fi
}

# Sets a variable with the defined variable name and value(s).
#  Shows an error and if the variable name is alredy defined and exits the script.
#
# $1 - Variable name
# $2 - Variable value(s)
set_variable()
{
  local varname=$1
  shift

  if [ -z "${!varname}" ]; then
    eval "$varname=\"$@\""
  else
    echo "Error: $varname already set"
    showHelp
  fi
}

# Tries to load the config file. If no path is defined the default path './dependencies.conf' will be tried.
loadConfig() {
    path=$1
    shift

    if [[ ! -z $path ]] && [[ -f $path ]]; then
        . ${path}
    elif [[ -f ./dependencies.config ]]; then
        . ./dependencies.config
    else
        echo -e "${bold}${red}Could not find configuration file.
Please define path with the -c switch or put the configuration file in the same directory as the script.${normal}"
       exit 1
    fi
}


# ------------------------------------------------------------------- #
# ----- Argument parsing -------------------------------------------- #
# ------------------------------------------------------------------- #
# Unset variables which possibly will be used for the script options
unset action config

# Loop through the script parameters with getopts and set the desired variables
while getopts 'sarc:?h' c
do
  case $c in
    s) set_variable action SHOW ;;
    a) set_variable action ADD ;;
    r) set_variable action REMOVE ;;
    c) set_variable config $OPTARG ;;
    h|?) showHelp ;; esac
done

# Remove switches from script arguments
shift $(expr $OPTIND - 1 )
# Get remaining arguments in array which are the project paths or dependency strings
args=("$@")

# Show help if no action switch is set or path/dependency argument is missing
[[ -z "$action" ]] && showHelp
[[ ${#args[@]} -eq 0 ]] && showHelp

# Load config
loadConfig ${config}

# ------------------------------------------------------------------- #
# ----- Main flow of the script ------------------------------------- #
# ------------------------------------------------------------------- #
if [[ ${action} == SHOW ]]; then 

    # Download/Update list with already deployed dependencies
    fetchDeployedDependencies

    for path in "${args[@]}"
    do
        # Check if path is a valid directory as well as an Maven project
        isValidMavenDirectory ${path}
        [[ $? == 1 ]] && continue

        # Show transitive dependencies of Maven project 
        showDependencies ${path}
    done

    #showDependencies "${args[@]}"
    exit 0

elif [[ ${action} == ADD ]]; then 

    # Append dependency string to file on server
    for dependency in "${args[@]}"
    do
        isValidMavenDependency ${dependency}
        [[ $? == 1 ]] && continue

        # Append dependency string to list on server
        ssh -i ${HOME}/.ssh/${ssh_key} ${ssh_user}@${ssh_host} "echo ${dependency} >> ${remote_file_path}"
    done

elif [[ ${action} == REMOVE ]]; then 
    
    # Remove dependency strings from file on server
    for dependency in "${args[@]}"
    do
        isValidMavenDependency ${dependency}
        [[ $? == 1 ]] && continue

        # Remove dependency string from list on server
        ssh -i ${HOME}/.ssh/${ssh_key} ${ssh_user}@${ssh_host} "sed -i '/^${dependency}$/d' ${remote_file_path}"
    done
fi


