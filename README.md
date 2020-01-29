# Expr--Translator
Simple Logical Expressions Translator

## Examples of expressions:
*
```
A = net:/^10\.23[23]\./
C = host:/^ec01-/
= A AND C
```

* 
```
A = net:/^10\.23[67]\./
B = net:/^10\.242\./
C = host:/^ec02-/
= (A OR B) AND C
```
