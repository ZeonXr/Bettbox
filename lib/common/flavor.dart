const _flavorOverride = String.fromEnvironment('APP_FLAVOR');
const _isProduct = bool.fromEnvironment('dart.vm.product');
const _isProfile = bool.fromEnvironment('dart.vm.profile');
const _defaultFlavor = _isProduct || _isProfile ? 'prod' : 'dev';

class AppFlavor {
  static const value = _flavorOverride == '' ? _defaultFlavor : _flavorOverride;
  static const isDev = value == 'dev';

  static const appName = isDev ? 'Bettbox Dev' : 'Bettbox';
  static const dataDirName = isDev ? 'BettboxDev' : 'Bettbox';
  static const helperService = isDev
      ? 'BettboxDevHelperService'
      : 'BettboxHelperService';
  static const helperPipeName = isDev
      ? r'\\.\pipe\BettboxDev.Helper'
      : r'\\.\pipe\Bettbox.Helper';
  static const coreExecutableName = isDev ? 'BettboxDevCore' : 'BettboxCore';
  static const mainExecutableName = 'Bettbox';
  static const tunDeviceName = isDev ? 'BettboxDev' : 'Bettbox';
  static const packageName = isDev
      ? 'com.appshub.bettbox.dev'
      : 'com.appshub.bettbox';
}
