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
GitHubApi = require "github"
weighted  = require "weighted"

module.exports = (robot) ->
  ghToken               = process.env.HUBOT_GITHUB_TOKEN
  ghOrg                 = process.env.HUBOT_GITHUB_ORG
  ghDefaultReviewerTeam = process.env.HUBOT_GITHUB_REVIEWER_TEAM
  ghWithAvatar          = process.env.HUBOT_GITHUB_WITH_AVATAR
  normalMessage         = process.env.HUBOT_REVIEWER_LOTTO_MESSAGE || "Please review this."
  politeMessage         = process.env.HUBOT_REVIEWER_LOTTO_POLITE_MESSAGE || "#{normalMessage} :bow::bow::bow::bow:"
  debug                 = process.env.HUBOT_REVIEWER_LOTTO_DEBUG in ["1", "true"]

  STATS_KEY             = 'reviewer-lotto-stats'
  PULL_REQUEST_QUEUE    = 'pull-request-queue'
  REPO_TEAMS            = 'repo-team-assignments'

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

    old_pr_queue = robot.brain.get PULL_REQUEST_QUEUE
    new_pr_queue = {}

    repos = _.keys old_pr_queue

    _.each repos, (repo) ->
      pr_numbers = old_pr_queue[repo]

      _.each pr_numbers, (pr_number) ->
        params =
          user: ghOrg
          repo: repo
          number: pr_number

        gh.issues.getRepoIssue params, (err, res) ->
          label_names = _.map res['labels'], (label) -> label['name']

          if _.include(label_names, 'Awaiting CR')
            new_pr_queue[repo] or= []
            new_pr_queue[repo].push(pr_number)

            message = "ping @#{res['assignee']['login']}"
            params  = _.extend { body: message }, params
            gh.issues.createComment params, null

    robot.brain.set PULL_REQUEST_QUEUE, new_pr_queue

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
    repo   = msg.match[1]
    pr     = msg.match[2]
    polite = msg.match[3]?
    prParams =
      user: ghOrg
      repo: repo
      number: pr

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
          ctx['existing_labels'] = _.map res['labels'], (label) -> label['name']
          cb null, ctx

      (ctx, cb) ->
        # change assignee & assign label
        {reviewer} = ctx
        new_labels = ctx['existing_labels'].concat('Awaiting CR')
        params = _.extend { assignee: reviewer.login, labels: new_labels }, prParams
        gh.issues.edit params, (err, res) -> cb err, ctx

      (ctx, cb) ->
        # add pr to watch list
        pr_queue = (robot.brain.get PULL_REQUEST_QUEUE) or {}
        pr_queue[repo] or= []
        pr_queue[repo] = _.union pr_queue[repo], [parseInt(pr)]
        robot.brain.set PULL_REQUEST_QUEUE, pr_queue
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

  robot.respond /reviewer clear team for ([\w-\.]+)/i, (msg) ->
    repo   = msg.match[1]

    repoTeams = (robot.brain.get REPO_TEAMS) or {}
    delete repoTeams[repo]

    robot.brain.set REPO_TEAMS, repoTeams
    msg.send "Team cleared for repo: *#{repo}*."

  robot.respond /reviewer list (assignments| team assignments)/i, (msg) ->
    repoTeams = (robot.brain.get REPO_TEAMS) or {}

    response = "*Current repo/team assignments:*\n" +
               "*DEFAULT*           - Team Id: *#{ghDefaultReviewerTeam}*"

    for repo, teamId of repoTeams
      response += "\nRepo: *#{repo}* - Team Id: *#{teamId}*"

    msg.send response

  robot.respond /reviewer ping crs/i, (msg) ->
    pingCodeReviews
    msg.send "All CRs have been pinged."

  robot.respond /reviewer show crs/i, (msg) ->
    pr_queue = robot.brain.get PULL_REQUEST_QUEUE
    msg.send "Listing PR Queue\n#{JSON.stringify(pr_queue)}"

  # robot.respond /reviewer clear crs/i, (msg) ->
  #   robot.brain.set PULL_REQUEST_QUEUE, {}
  #   msg.send "CR Queue has been cleared."

  robot.respond /reviewer (help|\-\-h|\-h|\-help)/i, (msg) ->
    msg.send "*COMMANDS:*\n"                                                                          +
             ">_bot reviewer help_:   shows this help\n"                                              +
             ">_bot reviewer for *<repo>* *<pull>*_:   assigns random reviewer for pull request\n"    +
             ">_bot reviewer show stats_:   proves the lotto has no bias\n"                           +
             ">_bot reviewer reset stats_:   resets the reviewer stats\n"                             +
             ">_bot reviewer list team assignments_:   lists all team ids assigned to repos\n"        +
             ">_bot reviewer ping crs_:   pings all outstanding PRs awaiting code review\n"           +
             ">_bot reviewer set team *<id>* for *<repo>*_:   assigns a specific team id to a repo\n" +
             ">_bot reviewer clear team for *<repo>*_:   clears the team id for a repo"
