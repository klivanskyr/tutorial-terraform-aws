from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.exceptions import TokenError
from rest_framework_simplejwt.tokens import RefreshToken


class LogoutView(APIView):
    """
    POST /api/auth/logout/

    Blacklists the refresh token (so it can't be used to mint new access tokens
    even if someone extracted it from a cookie) and clears both auth cookies.

    AllowAny so a user with an expired access token can still log out.
    """

    permission_classes = [AllowAny]

    def post(self, request):
        refresh_token = request.COOKIES.get('refresh_token')
        if refresh_token:
            try:
                RefreshToken(refresh_token).blacklist()
            except TokenError:
                pass  # Already expired or invalid — fine, we're logging out anyway

        response = Response({'message': 'Logged out'})
        response.delete_cookie('access_token',  samesite='Lax')
        response.delete_cookie('refresh_token', samesite='Lax')
        return response
