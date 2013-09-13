/*
 * Implementation of ECMA Script 5 like bind from:
 * https://developer.mozilla.org/en/JavaScript/Reference/Global_Objects/Function/bind
 */
if (!Function.prototype.bind) {
  Function.prototype.bind = function (oThis) {
    if (typeof this !== "function") {
      /* closest thing possible to the ECMAScript 5 internal IsCallable function */
      throw new TypeError("Function.prototype.bind - what is trying to be bound is not callable");
    }
    var fSlice = Array.prototype.slice,
        aArgs = fSlice.call(arguments, 1),
        fToBind = this,
        fNOP = function () {},
        fBound = function () {
          return fToBind.apply(this instanceof fNOP ? this : oThis || window, Args.concat(fSlice.call(arguments)));
        };
    fNOP.prototype = this.prototype;
    fBound.prototype = new fNOP();
    return fBound;
  };
}

Strophe.addNamespace("ADHOC", "http://jabber.org/protocol/commands");

function Adhoc(view, readycb) {
    this.status = {
        sessionid: null,
        cmdNode: null,
        queryJID: null,
	readycb: readycb,
	view: view
    };
}

Adhoc.prototype = {
    constructor: Adhoc,

    addNote: function (text, type) {
        if (!type) {
           type = "info";
        }
        text = text.replace(/\n/g, "<br/>");
        $(this.status.view).append("<p class='" + type + "Note'>" + text + "</p>");
    },

    addForm: function (x) {
        var self = this;
        var form = $("<form class='form-stacked' action='#'/>");
        form.submit(function(event) {
            self.executeCommand("execute", self.serializeToDataform('form'),
                function(e) { self.displayResult(e) });
            event.preventDefault();
        });
        var fieldset = $("<fieldset/>");
        form.append(fieldset);
        $(x).find("title").each(function() { $("<legend/>").text($(this).text()).appendTo(fieldset); });
        $(x).find("instructions").each(function() { $("<p/>").text($(this).text()).appendTo(fieldset); });
        $(x).find("field").each(function() {
	    var clearfix = $("<div class='clearfix'/>");
            var item = self.buildHTMLField(this);
            var label = $(this).attr("label");
            if(label) {
                $("<label/>").text(label).attr("for", $(this).attr("var")).appendTo(clearfix);
            }
            if ($(x).attr("type") === "result")
                item.attr("readonly", true);
            clearfix.append(item);
            fieldset.append(clearfix);
        });
        $(self.status.view).append(form);
    },

    buildHTMLField: function(fld) {
        var field = $(fld), html = {
            "hidden"	  : "<input type='hidden'/>",
            "boolean"	  : "<input type='checkbox'/>",
            "fixed"       : "<input type='text' readonly='true'/>",
            "text-single" : "<input type='text'/>",
            "text-private": "<input type='password'/>",
            "text-multi"  : "<textarea rows='10' cols='70'/>",
            "jid-single"  : "<input type='text'/>",
            "jid-multi"   : "<textarea rows='10' cols='70'/>",
            "list-single" : "<select/>",
            "list-multi"  : "<select multiple='multiple'/>",
        };
        var type = field.attr('type');
        var input = $(html[type] || "<input/>");
        var name = field.attr("var");

        input.addClass("df-item");
        if (name) {
            input.attr("name", name);
            input.attr("id", name);
        }

        if (field.find("required").length > 0)
            input.attr("required", "required");

        /* Add possible values to the lists */
        if (type === 'list-multi' || type==='list-single') {
            field.find("option").each(function() {
                var option = $("<option/>");
                option.text($(this).attr("label"));
                option.val($(this).find("value").text());
                input.append(option);
            });
        }

        /* Add/select default values */
        field.children("value").each(function() {
            var value = $(this).text();
            if ((type === "text-multi") || (type === "jid-multi")) {
                input.text(input.text() + value + "\n"); /* .append() would work, but doesn't escape */
            } else if (type === "list-multi") {
                input.children('option[value="' + value + '"]').each(function() {
                    $(this).attr("selected", "selected");
                });
            } else {
                input.val(value);
            }
        });

        return input;
    },

    serializeToDataform: function (form) {
        st = $build("x", {"xmlns": "jabber:x:data", "type": "submit"});
        $(form).find(".df-item").each(function(){
            st.c("field", {"var": $(this).attr("name")});
            if (this.nodeName.toLowerCase() === "select" && this.multiple) {
                for (var i = 0; i < this.options.length; i++)
                    if (this.options[i].selected)
                        st.c("value").t(this.options[i].text).up();
            } else if (this.nodeName.toLowerCase() === "textarea") {
                var sp_value = this.value.split(/\r?\n|\r/g);
                for(var i = 0; i < sp_value.length; i++)
                    st.c("value").t(sp_value[i]).up();
            } else if (this.nodeName.toLowerCase() === "input" && this.type === "checkbox") {
                if (this.checked) {
                    st.c("value").t("1");
                } else {
                    st.c("value").t("0");
                }
            } else {
                /* if this has value then */
                st.c("value").t($(this).val()).up();
            }
            st.up();
        });
        st.up();
        return st.tree();
    },

    displayResult: function (result) {
        var self = this;
        var status = $(result).find("command").attr("status");
        var kinds = {'prev': 'Prev', 'next': 'Next', 'complete': 'Complete'};

        $(self.status.view).empty();
        $(result).find("command > *").each(function() {
            if ($(this).is("note")) {
                self.addNote($(this).text(), $(this).attr("type"));
            } else if ($(this).is("x[xmlns=jabber:x:data]")) {
                self.addForm(this);
            }
        });
        if (status === "executing") {
	    var controls = $("<div class='actions'/>");
            for (kind in kinds) {
		var input;
                (function(type) {
                    input = $("<input type='button' disabled='disabled' class='btn' value='" + kinds[type] + "'/>").click(function() {
                        self.executeCommand(type, (type!= 'prev') && self.serializeToDataform('form'), function(e) { self.displayResult(e) });
                    }).appendTo(controls);
                })(kind);
                if ($(result).find('actions ' + kind).length > 0)
                    input.removeAttr("disabled");
            }

            $("<input type='button' id='executeButton' class='btn primary' value='Execute'/>").click(function() {
                self.executeCommand("execute", self.serializeToDataform('form'), function(e) { self.displayResult(e) });
            }).appendTo(controls);

            $("<input type='button' class='btn' value='Cancel'/>").click(function() {
                self.cancelCommand(function(e) { self.displayResult(e) });
            }).appendTo(controls);
	    $(self.status.view + " fieldset").append(controls);
        } else {
	    self.status.sessionid = null;
	    self.status.cmdNode = null;
	    self.status.readycb();
        }
    },

    runCommand: function (item, callback) {
        var cb;
        this.status.cmdNode = $(item).attr("id"); /* Save node of executed command */
        cb = function(result) {
            this.status.sessionid = $(result).find("command").attr("sessionid");
            callback(result);
        }
        this.executeCommand("execute", false, cb.bind(this));
    },

    executeCommand: function (type, childs, callback) {
        if (this.status.sessionid)
            var execIQ = $iq({ type: "set", to: this.status.queryJID, id: connection.getUniqueId() })
                .c("command", { xmlns: Strophe.NS.ADHOC, node: this.status.cmdNode, sessionid: this.status.sessionid, action: type });
        else
            var execIQ = $iq({ type: "set", to: this.status.queryJID, id: connection.getUniqueId() })
                .c("command", { xmlns: Strophe.NS.ADHOC, node: this.status.cmdNode, action: type });
        if (childs)
            execIQ.cnode(childs);
            connection.sendIQ(execIQ, callback);
    },

    cancelCommand: function (callback) {
	if (this.status.cmdNode == null) return;
        this.executeCommand("cancel", false, callback);
        this.status.cmdNode = null
        this.status.sessionid = null;
    },

    getCommandNodes: function (callback) {
        var self = this;
        var nodesIQ = $iq({ type: "get", to: self.status.queryJID, id: connection.getUniqueId() }).c("query", {xmlns: Strophe.NS.DISCO_ITEMS, node: Strophe.NS.ADHOC});
        connection.sendIQ(nodesIQ, function(result) {
            var items = $("<ul></ul>");
            $(result).find("item").each(function() {
                $("<li></li>").append($("<a href='#' id='" + $(this).attr("node") + "'>" + $(this).attr("name") + "</a>").click(function (event) {
		    self.cancelCommand(function(){});
                    self.runCommand(this, function (result) { self.displayResult(result); });
                    event.preventDefault();
                })).appendTo(items);
            });
	    callback(items);
        });
    },

    checkFeatures: function (jid, cb, ecb) {
	var callback;
        if (this.status.sessionid)
            this.cancelCommand();
        this.status.queryJID = jid;
        var featureIQ = $iq({ type: "get", to: this.status.queryJID, id: connection.getUniqueId() }).c("query", {xmlns: Strophe.NS.DISCO_INFO});
        $(this.status.view).empty();

	function callback(result) {
	    if ($(result).find("feature[var='" + Strophe.NS.ADHOC + "']").length > 0) {
		cb(result);
	    } else {
		ecb(result);
	    }
	}

        connection.sendIQ(featureIQ, callback, ecb);
    }
}
