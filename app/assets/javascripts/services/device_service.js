angular.module("multiroomApp").factory('Device', function($rootScope, HttpErrorWrapper) {
  return {

    get: function(success, error) {
      HttpErrorWrapper.get("/api/devices/get", success, error);
    },

    refresh: function(success, error) {
      HttpErrorWrapper.get("/api/devices/refresh", success, error);
    },

    volume_change: function(friendly_name, volume_level, success, error) {
      HttpErrorWrapper.get("/api/devices/volume_change/" + friendly_name + "/" + volume_level, success, error);
    },

    select_cast: function(friendly_name, success, error) {
      HttpErrorWrapper.get("/api/devices/select/" + friendly_name, success, error);
    }
  };
});
