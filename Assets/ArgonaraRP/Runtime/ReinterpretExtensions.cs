using System.Runtime.InteropServices;

public static class ReinterpretExtensions
{
    [StructLayout(LayoutKind.Explicit)]
    struct IntFloat
    {
        [FieldOffset(0)]
        public int intValue;

        [FieldOffset(0)]
        public float floatValue;
    }

    public static float ReinterpretAsFloat(this int value)//将int的位模式原样解释为float，避免数值转换破坏掩码
    {
        IntFloat converter = default;
        converter.intValue = value;
        return converter.floatValue;
    }
}
