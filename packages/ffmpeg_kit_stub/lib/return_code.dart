class ReturnCode {
  final int _value;
  const ReturnCode(this._value);
  int getValue() => _value;

  static bool isSuccess(ReturnCode? code) =>
      code != null && code._value == 0;

  static bool isCancel(ReturnCode? code) => false;
}
