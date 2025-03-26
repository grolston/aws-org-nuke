#!/bin/bash

export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS=5

set -e
error_handler() {
    echo "Error occurred in script at line: ${1}"
    exit 1
}

trap 'error_handler ${LINENO}' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if AWS CLI command was successful
check_aws_command() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}AWS CLI command failed${NC}"
        exit 1
    fi
}

# Function to get service principals for an account
get_service_principals() {
    local account_id="$1"
    aws organizations list-delegated-services-for-account \
        --account-id "$account_id" \
        --query 'DelegatedServices[].ServicePrincipal' \
        --output text
}

# Function to deregister administrator for a service
deregister_admin() {
    local account_id="$1"
    local service_principal="$2"

    echo -e "${YELLOW}Deregistering account $account_id for service $service_principal${NC}"
    aws organizations deregister-delegated-administrator \
        --account-id "$account_id" \
        --service-principal "$service_principal"

    check_aws_command
    echo -e "${GREEN}Successfully deregistered $account_id for $service_principal${NC}"
}

# Function to close a member account
close_member_account() {
    local account_id="$1"
    local account_name="$2"

    echo -e "${YELLOW}Closing account $account_name ($account_id)...${NC}"

    # Close the account using organizations close-account
    aws organizations close-account \
        --account-id "$account_id"

    check_aws_command
    echo -e "${GREEN}Successfully initiated closure for account $account_name ($account_id)${NC}"
}

# Function to get all member accounts
get_member_accounts() {
    aws organizations list-accounts \
        --query 'Accounts[?Status==`ACTIVE`].[Id,Name,Email]' \
        --output text
}

# Function to check account closure status
check_account_status() {
    local account_id="$1"
    local status=$(aws organizations list-accounts \
        --query "Accounts[?Id=='$account_id'].Status" \
        --output text)
    echo "$status"
}

main() {
    echo -e "${YELLOW}Starting AWS Organization cleanup...${NC}"

    # Get management account ID
    management_account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    check_aws_command


    # Step 1: Deregister delegated administrators
    echo -e "${YELLOW}Step 1: Deregistering delegated administrators...${NC}"

    delegated_admins=$(aws organizations list-delegated-administrators \
        --query 'DelegatedAdministrators[].Id' \
        --output text)

    check_aws_command

    if [ -n "$delegated_admins" ]; then
        for admin_account in $delegated_admins; do
            echo "Processing account: $admin_account"

            service_principals=$(get_service_principals "$admin_account")
            check_aws_command

            if [ -n "$service_principals" ]; then
                for service_principal in $service_principals; do
                    deregister_admin "$admin_account" "$service_principal"
                    sleep 2
                done
            fi
        done
    else
        echo "No delegated administrators found."
    fi

    # Step 2: Close member accounts
    echo -e "${YELLOW}Step 2: Closing member accounts...${NC}"

    member_accounts=$(get_member_accounts)
    check_aws_command

    closed_accounts=()
    if [ -n "$member_accounts" ]; then
        while IFS=$'\t' read -r account_id account_name account_email; do
            if [ "$account_id" != "$management_account_id" ]; then
                close_member_account "$account_id" "$account_name"
                closed_accounts+=("$account_id")
                sleep 15
            fi
        done <<< "$member_accounts"
    else
        echo "No member accounts found."
    fi

    # Monitor account closure status
    if [ ${#closed_accounts[@]} -gt 0 ]; then
        echo -e "${YELLOW}Monitoring account closure status...${NC}"
        all_suspended=false
        retry_count=0
        max_retries=30

        while [ "$all_suspended" = false ] && [ $retry_count -lt $max_retries ]; do
            all_suspended=true
            for account_id in "${closed_accounts[@]}"; do
                status=$(check_account_status "$account_id")
                echo -e "Account $account_id status: $status"
                if [ "$status" != "SUSPENDED" ]; then
                    all_suspended=false
                fi
            done

            if [ "$all_suspended" = false ]; then
                echo "Waiting for all accounts to be suspended..."
                sleep 30
                ((retry_count++))
            fi
        done

        if [ $retry_count -eq $max_retries ]; then
            echo -e "${RED}Timeout waiting for accounts to be suspended${NC}"
        else
            echo -e "${GREEN}All member accounts have been suspended${NC}"
        fi
    fi

    echo -e "${GREEN}AWS Organization cleanup completed successfully${NC}"
    echo -e "${YELLOW}Note: The management account ($management_account_id) must be closed manually through the AWS Console${NC}"
    echo -e "${YELLOW}Please ensure all member accounts are fully suspended before proceeding with management account closure${NC}"
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if AWS credentials are configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}AWS credentials are not configured or are invalid.${NC}"
    exit 1
fi

# Execute main function
main
