resource "aws_iam_role" "dns_lab_instance" {
  name = "dns-lab-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dns_lab_instance" {
  name = "dns-lab-instance-policy"
  role = aws_iam_role.dns_lab_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.dns_lab.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.dns_lab_scripts.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "dns_lab_ssm" {
  role       = aws_iam_role.dns_lab_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dns_lab" {
  name = "dns-lab-instance-profile"
  role = aws_iam_role.dns_lab_instance.name
}
