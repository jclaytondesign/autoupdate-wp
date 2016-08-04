#!/bin/bash

MULTIDEV="update-wp"

UPDATES_APPLIED=false

# login to Terminus
echo -e "\nlogging into Terminus..."
terminus auth login --machine-token=${TERMINUS_MACHINE_TOKEN}

# delete the multidev environment
echo -e "\ndeleting the ${MULTIDEV} multidev environment..."
terminus site delete-env --site=${SITE_UUID} --env=${MULTIDEV} --remove-branch --yes

# recreate the multidev environment
echo -e "\nre-creating the ${MULTIDEV} multidev environment..."
terminus site create-env --site=${SITE_UUID} --from-env=live --to-env=${MULTIDEV}

# making sure the multidev is in git mode
echo -e "\nsetting the ${MULTIDEV} multidev to git mode"
terminus site set-connection-mode --site=${SITE_UUID} --env=${MULTIDEV} --mode=git

# apply upstream updates, if applicable
echo -e "\napplying upstream updates to the ${MULTIDEV} multidev..."
terminus site upstream-updates apply --site=${SITE_UUID} --env=${MULTIDEV}

# making sure the multidev is in SFTP mode
echo -e "\nsetting the ${MULTIDEV} multidev to SFTP mode"
terminus site set-connection-mode --site=${SITE_UUID} --env=${MULTIDEV} --mode=sftp

# check for WordPress plugin updates
echo -e "\nchecking for WordPress plugin updates on the ${MULTIDEV} multidev..."
PLUGIN_UPDATES=$(terminus wp "plugin list --field=update" --site=${SITE_UUID} --env=${MULTIDEV} --format=bash)

if [[ ${PLUGIN_UPDATES} == *"available"* ]]
then
    # update WordPress plugins
    echo -e "\nupdating WordPress plugins on the ${MULTIDEV} multidev..."
    terminus wp "plugin update --all" --site=${SITE_UUID} --env=${MULTIDEV}

    # committing updated WordPress plugins
    echo -e "\ncommitting WordPress plugin updates on the ${MULTIDEV} multidev..."
    terminus site code commit --site=${SITE_UUID} --env=${MULTIDEV} --message="update WordPress plugins" --yes
    UPDATES_APPLIED=true
else
    # no WordPress plugin updates found
    echo -e "\nno WordPress plugin updates found on the ${MULTIDEV} multidev..."
fi

# check for WordPress theme updates
echo -e "\nchecking for WordPress theme updates on the ${MULTIDEV} multidev..."
THEME_UPDATES=$(terminus wp "theme list --field=update" --site=${SITE_UUID} --env=${MULTIDEV} --format=bash)

if [[ ${THEME_UPDATES} == *"available"* ]]
then
    # update WordPress themes
    echo -e "\nupdating WordPress plugins on the ${MULTIDEV} multidev..."
    terminus wp "theme update --all" --site=${SITE_UUID} --env=${MULTIDEV}

    # committing updated WordPress themes
    echo -e "\ncommitting WordPress theme updates on the ${MULTIDEV} multidev..."
    terminus site code commit --site=${SITE_UUID} --env=${MULTIDEV} --message="update WordPress themes" --yes
    UPDATES_APPLIED=true
else
    # no WordPress theme updates found
    echo -e "\nno WordPress theme updates found on the ${MULTIDEV} multidev..."
fi

# visual regression with Bactrack
# echo -e "\nstarting visual regression test between live and the ${MULTIDEV} multidev..."
# curl --header 'x-api-key: b0d82d371962671ebb02c5080a8f0a59' --request POST https://backtrac.io/api/project/24520/compare_prod_dev

# install node dependencies
echo -e "\nrunning npm install..."
npm install

# ping the multidev environment to wake it from sleep
echo -e "\npinging the ${MULTIDEV} multidev environment to wake it from sleep..."
curl -I https://update-wp-wp-microsite.pantheonsite.io/

# backstop visual regression
echo -e "\nrunning BackstopJS tests..."

cd node_modules/backstopjs

npm run reference
# npm run test

VISUAL_REGRESSION_RESULTS=$(npm run test)

echo "${VISUAL_REGRESSION_RESULTS}"

cd -

if [[ "${UPDATES_APPLIED}" = false ]]
then
    # no updates to apply
    echo -e "\nNo updates to apply..."
    SLACK_MESSAGE="scalewp.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME}. No updates to apply, nothing deployed."
    echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
    curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
    exit 0
fi

if [[ ${VISUAL_REGRESSION_RESULTS} == *"Mismatch errors found"* ]]
then
    # visual regression failed
    echo -e "\nVisual regression tests failed! Please manually check the ${MULTIDEV} multidev..."
    SLACK_MESSAGE="scalewp.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME}. Visual regression tests failed on <https://dashboard.pantheon.io/sites/${SITE_UUID}#${MULTIDEV}/code|the ${MULTIDEV} environment>! Please test manually."
    echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
    curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
    exit 1
else
    # visual regression passed
    echo -e "\nVisual regression tests passed between the ${MULTIDEV} multidev and live."

    # enable git mode on dev
    echo -e "\nEnabling git mode on the dev environment..."
    terminus site set-connection-mode --site=${SITE_UUID} --env=dev --mode=git --yes

    # merge the multidev back to dev
    echo -e "\nMerging the ${MULTIDEV} multidev back into the dev environment (master)..."
    terminus site merge-to-dev --site=${SITE_UUID} --env=${MULTIDEV}

    # deploy to test
    echo -e "\nDeploying the updates from dev to test..."
    terminus site deploy --site=${SITE_UUID} --env=test --sync-content --cc --note="Auto deploy of WordPress updates (core, plugin, themes)"

    # deploy to live
    echo -e "\nDeploying the updates from test to live..."
    terminus site deploy --site=${SITE_UUID} --env=live --cc --note="Auto deploy of WordPress updates (core, plugin, themes)"

    echo -e "\nVisual regression tests passed! WordPress updates deployed to live..."
    SLACK_MESSAGE="scalewp.io Circle CI update check #${CIRCLE_BUILD_NUM} by ${CIRCLE_PROJECT_USERNAME} Visual regression tests passed! WordPress updates deployed to <https://dashboard.pantheon.io/sites/${SITE_UUID}#live/deploys|the live environment>."
    echo -e "\nSending a message to the ${SLACK_CHANNEL} Slack channel"
    curl -X POST --data "payload={\"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"text\": \"${SLACK_MESSAGE}\"}" $SLACK_HOOK_URL
fi