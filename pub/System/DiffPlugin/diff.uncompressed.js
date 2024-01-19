/*
 * diff plugin 1.0
 *
 * Copyright (c) 2019-2024 Michael Daum https://michaeldaumconsulting.com
 *
 * Licensed under the GPL licenses http://www.gnu.org/licenses/gpl.html
 *
 */
"use strict";
(function($) {

  var defaults = {};

  function DiffManager(elem, opts) {
    var self = this;

    self.elem = $(elem);
    self.opts = $.extend({}, defaults, self.elem.data(), opts);

    self.init();
  }

  DiffManager.prototype.init = function () {
    var self = this, oldRev, newRev,i;

    self.oldSelect = self.elem.find(".foswikiDiffSelect[name='oldrev']"),
    self.newSelect = self.elem.find(".foswikiDiffSelect[name='newrev']");

    self.oldSelect.on("change", function() {
      self.onChange();
    });

    self.newSelect.on("change", function() {
      self.onChange();
    });

    oldRev = self.oldSelect.val();
    newRev = self.newSelect.val();

    self.oldSelect.empty();
    for (i = newRev-1; i > 0; i--) {
      $("<option>"+i+"</option>").appendTo(self.oldSelect).prop("selected", i == oldRev);
    }

    self.newSelect.empty();
    for (i = self.opts.maxRev; i > oldRev; i--) {
      $("<option>"+i+"</option>").appendTo(self.newSelect).prop("selected", i == newRev);
    }
  };

  DiffManager.prototype.onChange = function() {
    var self = this;

    window.location.href = window.location.pathname + "?oldrev="+self.oldSelect.val()+"&newrev="+self.newSelect.val();
  };


  $(".foswikiDiffContainer").livequery(function() {
    var $this = $(this);

    if (!$this.data("diffManager")) {
      $this.data("diffManager", new DiffManager(this));
    }
  });
})(jQuery);
