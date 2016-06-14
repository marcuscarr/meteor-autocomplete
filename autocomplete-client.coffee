AutoCompleteRecords = new Mongo.Collection("autocompleteRecords")

isServerSearch = (rule) -> _.isString(rule.collection)

validateRule = (rule) ->
  if rule.subscription? and not Match.test(rule.collection, String)
    throw new Error("Collection name must be specified as string for server-side search")

isWholeField = (rule) ->
  # either '' or null both count as whole field.
  return !rule.token

getRegExp = (rule) ->
  unless isWholeField(rule)
    # Expressions for the range from the last word break to the current cursor position
    new RegExp('(^|\\b|\\s)' + rule.token + '([\\w.]*)$')
  else
    # Whole-field behavior - word characters or spaces
    new RegExp('(^)(.*)$')

getFindParams = (rule, filter, limit) ->
  # This is a different 'filter' - the selector from the settings
  # We need to extend so that we don't copy over rule.filter
  selector = _.extend({}, rule.filter || {})
  options = { limit: limit }

  # Match anything, no sort, limit X
  return [ selector, options ] unless filter

  if rule.sort and rule.field
    sortspec = {}
    # Only sort if there is a filter, for faster performance on a match of anything
    sortspec[rule.field] = 1
    options.sort = sortspec

  if _.isFunction(rule.selector)
    # Custom selector
    _.extend(selector, rule.selector(filter))
  else
    selector[rule.field] = {
      $regex: if rule.matchAll then filter else "^" + filter
      # default is case insensitive search - empty string is not the same as undefined!
      $options: if (typeof rule.options is 'undefined') then 'i' else rule.options
    }

  return [ selector, options ]

getField = (obj, str) ->
  obj = obj[key] for key in str.split(".")
  return obj

class @AutoComplete

  @KEYS: [
    40, # DOWN
    38, # UP
    13, # ENTER
    27, # ESCAPE
    9   # TAB
  ]

  constructor: (settings) ->
    @limit = settings.limit || 5
    @position = settings.position || "bottom"
    @minChars = settings.minChars || 3

    @rules = settings.rules
    validateRule(rule) for rule in @rules

    @expressions = (getRegExp(rule) for rule in @rules)

    @matched = -1
    @loaded = true

    # Reactive dependencies for current matching rule and filter
    @ruleDep = new Deps.Dependency
    @filterDep = new Deps.Dependency
    @loadingDep = new Deps.Dependency

    # autosubscribe to the record set published by the server based on the filter
    # This will tear down server subscriptions when they are no longer being used.
    @sub = null
    @comp = Deps.autorun =>
      # Stop any existing sub immediately, don't wait
      @sub?.stop()

      return unless (rule = @matchedRule()) and (filter = @getFilter()) isnt null

      # subscribe only for server-side collections
      unless isServerSearch(rule)
        @setLoaded(true) # Immediately loaded
        return

      [ selector, options ] = getFindParams(rule, filter, @limit)

      # console.debug 'Subscribing to <%s> in <%s>.<%s>', filter, rule.collection, rule.field
      @setLoaded(false)
      subName = rule.subscription || "autocomplete-recordset"
      processScopeIds = rule.processScopeIds
      @sub = Meteor.subscribe(subName,
        selector, options, rule.collection, processScopeIds, => @setLoaded(true))

  teardown: ->
    # Stop the reactive computation we started for this autocomplete instance
    @comp.stop()

  # reactive getters and setters for @filter and the currently matched rule
  matchedRule: ->
    @ruleDep.depend()
    if @matched >= 0 then @rules[@matched] else null

  setMatchedRule: (i) ->
    @matched = i
    @ruleDep.changed()

  getFilter: ->
    @filterDep.depend()
    return @filter

  setFilter: (x) ->
    @filter = x
    @filterDep.changed()
    return @filter

  isLoaded: ->
    @loadingDep.depend()
    return @loaded

  setLoaded: (val) ->
    return if val is @loaded # Don't cause redraws unnecessarily
    @loaded = val
    @loadingDep.changed()

  onKeyUp: ->
    return unless @$element # Don't try to do this while loading
    @$element.removeClass("chosen")

    startpos = @element.selectionStart
    val = @getText().substring(0, startpos)

    # wait for at least n chars before commencing search
    if val.length < @minChars
      @hideList()
      return

    if (val.substring(0,1) in ["~", "@"]) and val.length < 4
      @hideList()
      return
    ###
      Matching on multiple expressions.
      We always go from a matched state to an unmatched one
      before going to a different matched one.
    ###
    i = 0
    breakLoop = false
    while i < @expressions.length
      matches = val.match(@expressions[i])

      # matching -> not matching
      if not matches and @matched is i
        @setMatchedRule(-1)
        breakLoop = true

      # not matching -> matching
      if matches and @matched is -1
        @setMatchedRule(i)
        breakLoop = true

      # Did filter change?
      if matches and @filter isnt matches[2]
        @setFilter(matches[2])
        breakLoop = true

      break if breakLoop
      i++

  onKeyDown: (e) ->
    return if @matched is -1 or (@constructor.KEYS.indexOf(e.keyCode) < 0)

    switch e.keyCode
      when 9, 13 # TAB, ENTER
        e.preventDefault()
        e.stopPropagation()
        return not @select() # Don't jump fields or submit if select successful

      # preventDefault needed below to avoid moving cursor when selecting
      when 40 # DOWN
        e.preventDefault()
        @next()
      when 38 # UP
        e.preventDefault()
        @prev()
      when 27 # ESCAPE
        @$element.blur()
        @hideList()

    return

  onFocus: ->
    # We need to run onKeyUp after the focus resolves,
    # or the caret position (selectionStart) will not be correct
    Meteor.defer => @onKeyUp()

  onBlur: (e) ->
    # We need to delay this so click events work
    # TODO this is a bit of a hack; see if we can't be smarter
    Meteor.setTimeout =>
      @hideList()
    , 200

  onItemClick: (doc, e) =>
    @processSelection(doc, @rules[@matched])

  onItemHover: (doc, e) ->
    @markSelected($(e.target).closest(".-autocomplete-item.selectable"))

  filteredList: ->
    # @ruleDep.depend() # optional as long as we use depend on filter, because list will always get re-rendered
    filter = @getFilter() # Reactively depend on the filter
    return null if @matched is -1

    rule = @rules[@matched]
    # Don't display list unless we have a token or a filter (or both)
    # Single field: nothing displayed until something is typed
    return null unless rule.token or filter

    [ selector, options ] = getFindParams(rule, filter, @limit)

    # Meteor.defer => @ensureSelection()

    # if server collection, the server has already done the filtering work

    # TODO: Add to rules to make this specific to the searches where it's necessary.
    if isServerSearch(rule)
      if rule.autocompleteSort
        hits = AutoCompleteRecords.find({}, options).fetch()
        val = @getText()
        return @autocompleteSort(hits, val)
      else
        return AutoCompleteRecords.find({}, options)

    # Otherwise, search on client
    if rule.autocompleteSort
      # Need to get back a lot of results to capture all prefix matches
      limit = options.limit
      options.limit = 50
      hits = rule.collection.find(selector, options).fetch()
      val = @getText()
      return @autocompleteSort(hits, val).slice(0, limit)
    else
      return rule.collection.find(selector, options)

  autocompleteSort: (hits, query_string) ->
    # Return the results that start with the query string first, sorted by length
    # All typeahead results on name come first, then all synonyms, finally all
    # symbols. BUT, a full-string match to a name or synonym is put first.
    typeaheadResults = _.filter( hits, (hit) ->
      return hit.name.search( "^#{query_string}.*" ) > -1 or
        _.any(hit.synonyms, (syn) -> syn.search( "^#{query_string}.*" ) > -1) or
        hit.symbol?.search( "^#{query_string}.*" ) > -1
    )
    typeaheadResults = _.sortBy( typeaheadResults, (hit) ->
      if query_string is hit.name or _.any(hit.synonyms, (syn) -> query_string is syn)
        return 0
      if hit.name.search( "^#{query_string}.*" ) > -1
        return hit.name.length
      else if _.any(hit.synonyms, (syn) -> syn.search( "^#{query_string}.*" ) > -1)
        matchingSynonym = _.find(hit.synonyms, (syn) -> syn.search( "^#{query_string}.*" ) > -1)
        return matchingSynonym.length + 100
      else
        return hit.symbol?.length + 200
    )
    otherResults = _.filter( hits, (hit) -> return hit not in typeaheadResults )

    # Then append the remaining results
    return typeaheadResults.concat( otherResults )

  isShowing: ->
    rule = @matchedRule()

    # Same rules as above
    showing = rule? and (rule.token or @getFilter())

    # Do this after the render
    # n.b. had to revert to a long timeout as asking jquery for the DOM height()
    # is not reliable in deployed environment where results arrive more slowly
    # and thus panel takes a while to reach full height

    if showing
      Meteor.setTimeout =>
        @positionContainer()
        @ensureSelection()
      , 150

    return showing

  # Handle selection of autocomplete result item
  select: () ->
    node = @tmplInst.find(".-autocomplete-item.selected")

    if not node?
      @triggerNoMatchAction()
      return false
    else if node.classList.contains("footer")
      @triggerFooterAction()
      return true
    else
      doc = Blaze.getData(node)
      return false unless doc # Don't select if nothing matched

      @processSelection(doc, @rules[@matched])
      return true

  processSelection: (doc, rule) ->
    replacement = getField(doc, rule.field)

    unless isWholeField(rule)
      @replace(replacement, rule)
      @hideList()

    else
      # Empty string or doesn't exist?
      # Single-field replacement: replace whole field
      @setText(replacement)

      # Field retains focus, but list is hidden unless another key is pressed
      # Must be deferred or onKeyUp will trigger and match again
      # TODO this is a hack; see above
      @onBlur()

    @$element
      .addClass("chosen")
      .trigger("chosen", doc)

  triggerFooterAction: (e) ->
    @$element
      .trigger(@rules[@matched].footerAction)
      .blur()
    @hideList()
    @setText("")

  triggerNoMatchAction: (e) ->
    action = @rules[@matched].noMatchAction
    inputText = @getText()

    @hideList()
    @setText("")

    if action
      @$element.trigger(action, inputText)

  # Replace the appropriate region
  replace: (replacement) ->
    startpos = @element.selectionStart
    fullStuff = @getText()
    val = fullStuff.substring(0, startpos)
    val = val.replace(@expressions[@matched], "$1" + @rules[@matched].token + replacement)
    posfix = fullStuff.substring(startpos, fullStuff.length)
    separator = (if posfix.match(/^\s/) then "" else " ")
    finalFight = val + separator + posfix
    @setText finalFight

    newPosition = val.length + 1
    @element.setSelectionRange(newPosition, newPosition)
    return

  hideList: ->
    @setMatchedRule(-1)
    @setFilter(null)

  getText: ->
    return @$element.val() || @$element.text()

  setText: (text) ->
    if @$element.is("input,textarea")
      @$element.val(text)
    else
      @$element.html(text)

  ###
    Rendering functions
  ###
  positionContainer: ->
    el = @$element
    position = el.position()
    rule = @matchedRule()

    style =
      position: 'absolute'
      left: position.left
      width: el.outerWidth()
      opacity: 1

    if @position is "auto"
      $results = @tmplInst.$(".-autocomplete-list")
      offset = el.offset()
      resultPanelHeight = $results.height() + el.outerHeight()

      positionAbove = (offset.top + resultPanelHeight) > $(document).height()

      if positionAbove
        console.log "positioning dropdown above"

        style.position = 'fixed'
        style.left = offset.left
        style.top = offset.top - $results.height()
        # TODO some kind of scroll handling - would probably suffice to hide on scroll
        $(window).one("scroll", @onBlur)
      else
        console.log "positioning dropdown below"
        style.top = position.top + el.outerHeight()

    else
      # In whole-field positioning, we don't move the container and make it the
      # full width of the field.
      # TODO allow this to render top as well, and possibly used in textareas?
      console.log "positioning dropdown relative to container"
      style.top = position.top + el.outerHeight() # position.offsetHeight

    @tmplInst.$(".-autocomplete-container").css(style)

  ensureSelection : ->
    # Re-render; make sure selected item is something in the list or none if list empty
    selectedItem = @tmplInst.$(".-autocomplete-item.selected")
    selectableItems = @tmplInst.$(".-autocomplete-item.selectable")

    unless selectedItem.length > 0 or selectableItems.length == 0
      @markSelected(selectableItems.first())

  # Select next item in list
  next: ->
    currentItem = @tmplInst.$(".-autocomplete-item.selected")
    return unless currentItem.length # Don't try to iterate an empty list

    next = currentItem.next(".selectable")

    if next.length
      @markSelected(next)
    else # End of list or lost selection; Go back to first item
      @markSelected(@tmplInst.$(".-autocomplete-item.selectable:first-child"))

  # Select previous item in list
  prev: ->
    currentItem = @tmplInst.$(".-autocomplete-item.selected")
    return unless currentItem.length # Don't try to iterate an empty list

    prev = currentItem.prev(".selectable")

    if prev.length
      @markSelected(prev)
    else # Beginning of list or lost selection; Go to end of list
      @markSelected(@tmplInst.$(".-autocomplete-item.selectable:last-child"))

  # Temporarily select an autocomplete item, triggering the appropriate callback
  markSelected: ($item) ->
    $items = @tmplInst.$(".-autocomplete-item.selectable")

    if $items.length == 0 and !Blaze.currentView
      return

    $items.removeClass("selected")
    $item.addClass("selected")

    if $item.hasClass("footer")
      return

    doc = Blaze.getData($item[0])
    # console.log("Marked as selected", doc)
    $item.trigger("selected", doc)

  # This doesn't need to be reactive because list already changes reactively
  # and will cause all of the items to re-render anyway
  currentTemplate: -> @rules[@matched].template

AutocompleteTest =
  records: AutoCompleteRecords
  getRegExp: getRegExp
  getFindParams: getFindParams
