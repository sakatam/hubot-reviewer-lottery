# Description:
#   assigns random reviewer for a pull request.
#
# Configuration:
#   HUBOT_GITHUB_TOKEN (required)
#   HUBOT_GITHUB_ORG (required)
#   HUBOT_GITHUB_REVIEWER_TEAM (required)
#     default github team id. this script will randomly pick a reviewer from
#     this team if a specific team has not been assigned to a repo.
#
# Commands:
#   hubot reviewer help                     - shows this help
#   hubot reviewer for <repo> <pull>        - assigns random reviewer for pull request
#   hubot reviewer show stats               - proves the lotto has no bias
#   hubot reviewer list team assignments    - lists all team ids assigned to repos
#   hubot reviewer ping crs                 - pings all outstanding code reviews
#   hubot reviewer set team <id> for <repo> - assigns a specific team id to a repo
#   hubot reviewer clear team for <repo>    - clears the team id for a repo
#
# Author:
#   sakatam

_         = require "underscore"
async     = require "async"
Cron      = require("cron").CronJob
GitHubApi = require "github"
weighted  = require "weighted"

module.exports = (robot) ->
  ghToken               = process.env.HUBOT_GITHUB_TOKEN
  ghOrg                 = process.env.HUBOT_GITHUB_ORG
  ghDefaultReviewerTeam = process.env.HUBOT_GITHUB_REVIEWER_TEAM
  ghWithAvatar          = process.env.HUBOT_GITHUB_WITH_AVATAR
  codeReviewChecklist   = "\n\n#### Code Review Checklist:\n"                                            +
                          "- **All Code**\n"                                                             +
                          "  - [ ] Intent of the code/changes are clear?\n"                              +
                          "  - [ ] Comments are provided whenever something may be unintuitive?\n"       +
                          "  - [ ] Implementation of the code/changes makes sense?\n"                    +
                          "  - [ ] Code/changes are free of typos and basic errors?\n"                   +
                          "  - [ ] Code/specs can be run on your local machine?\n"                       +
                          "  - [ ] Changes are not breaking a public API?\n"                             +
                          "    - [ ] If so, documentation is updated?\n"                                 +
                          "  - [ ] Code/changes don't reimplement existing features?\n"                  +
                          "  - [ ] Performance implications have been considered?\n"                     +
                          "  - [ ] Code/changes include all appropriate tests?\n"                        +
                          "- **Migrations**\n"                                                           +
                          "  - [ ] All migrations run on a clone of production data?\n"                  +
                          "  - [ ] All migrations are reversable: `rake db:rollback`?\n"                 +
                          "  - [ ] All migrations are backwards-compatible?\n"                           +
                          "    - [ ] All migrations check for the existence of any models referenced?\n" +                          
                          "- **Rake Tasks**\n"                                                           +
                          "  - [ ] All rake tasks run on a clone of production data?\n"                  +
                          "  - [ ] Code/changes include all appropriate tests?"
  normalMessage         = process.env.HUBOT_REVIEWER_LOTTO_MESSAGE || "Please review this." + codeReviewChecklist
  politeMessage         = process.env.HUBOT_REVIEWER_LOTTO_POLITE_MESSAGE || "#{normalMessage} :bow::bow::bow::bow:" + codeReviewChecklist
  debug                 = process.env.HUBOT_REVIEWER_LOTTO_DEBUG in ["1", "true"]

  STATS_KEY             = 'reviewer-lotto-stats'
  PULL_REQUEST_QUEUE    = 'pull-request-queue'
  REPO_TEAMS            = 'repo-team-assignments'
  GITHUB_ALIASES        = 'github-aliases'

  # draw lotto - weighted random selection
  draw = (reviewers, stats = null) ->
    max = if stats? then (_.max _.map stats, (count) -> count) else 0
    arms = {}
    sum = 0
    for {login} in reviewers
      weight = Math.exp max - (stats?[login] || 0)
      arms[login] = weight
      sum += weight
    # normalize weights
    for login, weight of arms
      arms[login] = if sum > 0 then weight / sum else 1
    if debug
      robot.logger.info 'arms: ', arms

    selected = weighted.select arms
    _.find reviewers, ({login}) -> login == selected

  pingCodeReviews = ->
    gh = new GitHubApi version: "3.0.0"
    gh.authenticate {type: "oauth", token: ghToken}

    oldPrQueue = (robot.brain.get PULL_REQUEST_QUEUE) or {}
    newPrQueue = {}

    repos = _.keys oldPrQueue

    _.each repos, (repo) ->
      oldPrs = oldPrQueue[repo]

      _.each oldPrs, (oldPr) ->
        params =
          user: ghOrg
          repo: repo
          number: oldPr['number']

        gh.issues.getRepoIssue params, (err, res) ->
          link       = res['html_url']
          labelNames = _.map res['labels'], (l) -> l['name']

          if _.include labelNames, 'Awaiting CR'
            newPrQueue[repo] or= []
            newPrQueue[repo].push(oldPr)

            if (Date.now() - oldPr['submitted']) >= (3 * 60 * 60 * 1000)  # 3 hours
              message = "You have a pending code review: #{link}"
              robot.send {room: getSlackHandleFromGithubUsername(res['assignee']['login'])}, message

    robot.brain.set PULL_REQUEST_QUEUE, newPrQueue

  getSlackHandleFromGithubUsername = (githubUsername) ->
    aliases = (robot.brain.get GITHUB_ALIASES) or {}
    aliases[githubUsername]

  setSlackHandleFromGithubUsername = (githubUsername, slackHandle) ->
    aliases = (robot.brain.get GITHUB_ALIASES) or {}
    aliases[githubUsername] = slackHandle

    robot.brain.set GITHUB_ALIASES, aliases

  deleteGithubUsername = (githubUsername) ->
    aliases = robot.brain.get GITHUB_ALIASES
    delete aliases[githubUsername]

    robot.brain.set GITHUB_ALIASES, aliases

  scheduledJob = new Cron('00 00 9-17 * * 1-5', (->
    pingCodeReviews()
  ), null, true, "American/Los Angeles")

  if !ghToken? or !ghOrg?
    return robot.logger.error """
      reviewer-lottery is not loaded due to missing configuration!
      #{__filename}
      HUBOT_GITHUB_TOKEN: #{ghToken}
      HUBOT_GITHUB_ORG: #{ghOrg}
    """

  robot.respond /reviewer reset stats/i, (msg) ->
    robot.brain.set STATS_KEY, {}
    msg.send "Reset reviewer stats!"

  robot.respond /reviewer show stats$/i, (msg) ->
    stats = robot.brain.get STATS_KEY
    msgs = ["*login, percentage, num assigned*"]
    total = 0

    for login, count of stats
      total += count
    for login, count of stats
      percentage = Math.floor(count * 100.0 / total)
      msgs.push "#{login}, #{percentage}%, #{count}"
    msg.send msgs.join "\n"

  robot.respond /reviewer for ([\w-\.]+) (\d+)( polite)?$/i, (msg) ->
    repo     = msg.match[1]
    prNumber = msg.match[2]
    polite   = msg.match[3]?

    newPr =
      number: parseInt(prNumber)
      submitted: Date.now()  # milliseconds since epoch

    console.log(JSON.stringify(newPr))

    prParams =
      user: ghOrg
      repo: repo
      number: prNumber

    gh = new GitHubApi version: "3.0.0"
    gh.authenticate {type: "oauth", token: ghToken}

    # mock api if debug mode
    if debug
      gh.issues.createComment = (params, cb) ->
        robot.logger.info "GitHubApi - createComment is called", params
        cb null
      gh.issues.edit = (params, cb) ->
        robot.logger.info "GitHubApi - edit is called", params
        cb null

    async.waterfall [
      (cb) ->
        # get team members
        repoTeams     = (robot.brain.get REPO_TEAMS) or {}
        ghReviwerTeam = repoTeams[repo] or ghDefaultReviewerTeam

        params =
          id: ghReviwerTeam
          per_page: 100

        gh.orgs.getTeamMembers params, (err, res) ->
          return cb "error on getting team members: #{err.toString()}" if err?

          cb null, {reviewers: res}

      (ctx, cb) ->
        # check if pull req exists
        gh.pullRequests.get prParams, (err, res) ->
          return cb "error on getting pull request: #{err.toString()}" if err?

          ctx['issue']    = res
          ctx['creator']  = res.user
          ctx['assignee'] = res.assignee
          cb null, ctx

      (ctx, cb) ->
        # pick reviewer
        {reviewers, creator, assignee} = ctx
        reviewers = reviewers.filter (r) -> r.login != creator.login
        # exclude current assignee from reviewer candidates
        if assignee?
          reviewers = reviewers.filter (r) -> r.login != assignee.login

        ctx['reviewer'] = draw reviewers, robot.brain.get(STATS_KEY)
        cb null, ctx

      (ctx, cb) ->
        # post a comment
        {reviewer} = ctx
        body = "@#{reviewer.login} " + if polite then politeMessage else normalMessage
        params = _.extend { body }, prParams
        gh.issues.createComment params, (err, res) -> cb err, ctx

      (ctx, cb) ->
        # Get the existing labels
        gh.issues.getRepoIssue prParams, (err, res) ->
          ctx['existingLabels'] = _.map res['labels'], (l) -> l['name']
          cb null, ctx

      (ctx, cb) ->
        # change assignee & assign label
        {reviewer} = ctx
        newLabels = ctx['existingLabels'].concat('Awaiting CR')
        params = _.extend { assignee: reviewer.login, labels: newLabels }, prParams
        gh.issues.edit params, (err, res) -> cb err, ctx

      (ctx, cb) ->
        # add pr to watch list
        prQueue = (robot.brain.get PULL_REQUEST_QUEUE) or {}
        prQueue[repo] or= []
        existingPrNumbers = _.map prQueue[repo], (pr) -> pr['number']

        if ! _.include existingPrNumbers, newPr['number']
          prQueue[repo] = _.union prQueue[repo], [newPr]
          robot.brain.set PULL_REQUEST_QUEUE, prQueue

        cb null, ctx

      (ctx, cb) ->
        # tell the channel who has been assigned
        {reviewer, issue} = ctx
        msg.reply "#{reviewer.login} has been assigned for #{issue.html_url} as a reviewer"
        if ghWithAvatar
          url = reviewer.avatar_url
          url = "#{url}t=#{Date.now()}" # cache buster
          url = url.replace(/(#.*|$)/, '#.png') # hipchat needs image-ish url to display inline image
          msg.send url

        # update stats
        stats = (robot.brain.get STATS_KEY) or {}
        stats[reviewer.login] or= 0
        stats[reviewer.login]++
        robot.brain.set STATS_KEY, stats

        cb null, ctx
    ], (err, res) ->
      if err?
        msg.send "an error occured.\n#{err}"

  robot.respond /reviewer set team (\d+) for ([\w-\.]+)/i, (msg) ->
    teamId = msg.match[1]
    repo   = msg.match[2]

    repoTeams = (robot.brain.get REPO_TEAMS) or {}
    repoTeams[repo] = teamId

    robot.brain.set REPO_TEAMS, repoTeams
    msg.send "Team: *#{teamId}* set for repo: *#{repo}*."

  robot.respond /reviewer (show|list) teams/i, (msg) ->
    repoTeams = (robot.brain.get REPO_TEAMS) or {}

    response = "*Current repo/team assignments:*\n" +
               "*DEFAULT*           - Team Id: *#{ghDefaultReviewerTeam}*"

    for repo, teamId of repoTeams
      response += "\nRepo: *#{repo}* - Team Id: *#{teamId}*"

    msg.send response

  robot.respond /reviewer clear team for ([\w-\.]+)/i, (msg) ->
    repo   = msg.match[1]

    repoTeams = (robot.brain.get REPO_TEAMS) or {}
    delete repoTeams[repo]

    robot.brain.set REPO_TEAMS, repoTeams
    msg.send "Team cleared for repo: *#{repo}*."

  robot.respond /reviewer (show|list) crs/i, (msg) ->
    prQueue = robot.brain.get PULL_REQUEST_QUEUE
    msg.send "Listing PR Queue\n#{JSON.stringify(prQueue)}"

  robot.respond /reviewer clear crs/i, (msg) ->
    robot.brain.set PULL_REQUEST_QUEUE, {}
    msg.send "CR Queue has been cleared."

  robot.respond /reviewer set alias ([\w-\.]+) for ([\w-\.]+)/i, (msg) ->
    githubUsername = msg.match[1]
    slackHandle    = msg.match[2]

    console.log(githubUsername)
    console.log(slackHandle)

    setSlackHandleFromGithubUsername(githubUsername, slackHandle)
    msg.send "Alias set: Github: #{githubUsername} mapped to Slack handle: #{slackHandle}."

  robot.respond /reviewer (show|list) aliases/i, (msg) ->
    aliases = robot.brain.get GITHUB_ALIASES
    msg.send "Listing Github aliases\n#{JSON.stringify(aliases)}"

  robot.respond /reviewer clear alias ([\w-\.]+)/i, (msg) ->
    githubUsername = msg.match[1]

    deleteGithubUsername(githubUsername)
    msg.send "Alias cleared: Github: #{githubUsername}."

  robot.respond /reviewer (help|\-\-h|\-h|\-help)/i, (msg) ->
    msg.send "*COMMANDS:*\n"                                                                                                    +
             ">_bot reviewer help_:   shows this help\n"                                                                        +
             ">_bot reviewer for *<repo>* *<pull>*_:   assigns random reviewer for pull request\n"                              +
             ">_bot reviewer show stats_:   proves the lotto has no bias\n"                                                     +
             ">_bot reviewer reset stats_:   resets the reviewer stats\n"                                                       +
             ">_bot reviewer set team *<id>* for *<repo>*_:   assigns a specific team id to a repo\n"                           +
             ">_bot reviewer show teams_:   lists all team ids assigned to repos\n"                                             +
             ">_bot reviewer clear team for *<repo>*_:   clears the team id for a repo\n"                                       +
             ">_bot reviewer set alias *<githubUsername>* for *<slackHandle>*_:   define a github username/slack handle pair\n" +
             ">_bot reviewer show aliases_:   list all github username/slack handle pairs\n"                                    +
             ">_bot reviewer clear alias *<githubUsername>*_:    clear a github username/slack handle pair\n"
